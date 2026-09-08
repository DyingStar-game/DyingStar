class_name RemoteTileSource
extends RefCounted
## Récupère des tuiles d'élévation depuis l'arborescence publiée par
## tools/publish_tiles.py, et les garde dans un cache disque plafonné.
##
## Phase 3 de docs/PLANET_CHUNK_STREAMING.md. C'est la moitié CLIENTE du format publié en
## phase 2 : URL, enveloppe, cartes de présence et cache. Un désaccord avec le publieur ne
## lèverait aucune erreur — il rendrait du terrain faux — d'où le fait que les deux moitiés
## soient testées sur les mêmes conventions.
##
## CE QU'IL NE FAIT PAS
## --------------------
## Il ne bloque jamais. [method request] met en file, [method take] rend ce qui est arrivé.
## Le chemin d'échantillonnage tourne sur WorkerThreadPool et ne doit sous aucun prétexte
## attendre le réseau : c'est l'appelant (PlanetTerrain) qui s'assure qu'une tuile est
## résidente AVANT de soumettre la tâche de mesh, et qui diffère le chunk sinon.
##
## TRANSPORT INJECTABLE
## --------------------
## [member fetcher] est un Callable(url) -> [code, PackedByteArray]. Par défaut il fait du
## HTTP ; les tests en injectent un qui sert une arborescence synthétique, ce qui rend
## toute la logique — construction d'URL, enveloppe, présence, cache, LRU — vérifiable sans
## serveur ni réseau.

const TILE_MAGIC := 0x4C545344   # "DSTL" en little-endian
const TILE_HEADER := 12
const FLAG_DEFLATE := 1

## Réponse de [method presence_of]. UNKNOWN n'est pas une erreur : la carte du shard n'est
## pas encore arrivée, et l'appelant doit différer plutôt que d'attendre.
enum { PRESENCE_UNKNOWN, PRESENCE_YES, PRESENCE_NO }
## Genres de travaux de la file du fil de téléchargement.
const JOB_TILE := 0
const JOB_PRESENCE := 1
const JOB_FLOOR := 2

## En-tête du plancher : magie, version, nombre d'entrées.
const FLOOR_MAGIC := 0x4C465344
const FLOOR_HEADER := 12
## Une entrée d'index : nside, ipix, offset, longueur, en uint32.
const FLOOR_ENTRY := 16

## Base servie, sans slash final. Ex. "http://127.0.0.1/dist".
var base_url: String = ""
var planet: String = ""
## Version de données, lue du pointeur. Elle est dans le CHEMIN, donc tout objet sous elle
## est immuable et le cache disque lui est propre.
var version: String = ""
var tile_res: int = 0
var nside_min: int = 0
var nside_max: int = 0
var shard_tiles: int = 4096
## Dernier niveau contenu dans floor.bin, annoncé par le serveur. 0 = pas de plancher
## servi, on retombe alors sur les tuiles isolées.
var floor_nside_max: int = 0
## Racine du cache disque. Chaque version a son sous-répertoire, donc changer de version
## n'invalide rien : on écrit ailleurs et on supprime les anciennes.
var cache_root: String = "user://tile_cache/"

## Connexion HTTP conservée entre deux tuiles. Propriété du fil de téléchargement seul :
## _http_get n'est atteint que depuis lui, il n'y a donc pas d'accès concurrent.
var _conn: HTTPClient = null
var _conn_host: String = ""
var _conn_port: int = 0

## Borne le cache disque. Null = pas d'éviction (le comportement des tests unitaires,
## qui n'écrivent qu'une poignée de tuiles).
var lru: TileCacheLru = null
## Callable(url) -> [code:int, body:PackedByteArray].
var fetcher: Callable = Callable()

## Fil de téléchargement. Le chemin d'échantillonnage tourne sur WorkerThreadPool ; y
## attendre une socket gèlerait la génération de terrain. Les demandes sont donc mises en
## file et servies ici, pendant que l'appelant diffère le chunk concerné.
var _thread: Thread = null
var _queue: Array[Vector3i] = []      # (ipix, nside, genre)
var _queued: Dictionary = {}          # "n/p" -> true, pour ne pas redemander
var _mutex: Mutex = Mutex.new()
var _sem: Semaphore = Semaphore.new()
var _quit: bool = false
## Compteurs par source, lus par le profilage : ce qui a été demandé, servi, refusé.
var stat_requested: int = 0
var stat_fetched: int = 0
var stat_failed: int = 0

## Cumuls de TOUT le processus, toutes planètes confondues — c'est le volume réellement
## descendu du réseau que l'on veut voir, pas celui d'une planète en particulier.
## Comptés sur les octets REÇUS, donc enveloppe et compression comprises : c'est ce qui a
## traversé le fil, pas ce que ça pèse une fois décodé.
static var net_tiles: int = 0
static var net_tile_bytes: int = 0
static var net_maps: int = 0
static var net_map_bytes: int = 0
static var net_failed: int = 0

## Allers-retours HTTP réellement émis. Distinct du nombre de tuiles : c'est le coût qui
## domine sur un vrai réseau, et c'est lui que la connexion conservée fait chuter.
static var net_requests: int = 0


## Une ligne lisible du volume téléchargé depuis le démarrage, ou "" si rien.
static func net_line() -> String:
	if net_tiles + net_maps + net_failed == 0:
		return ""
	var total := net_tile_bytes + net_map_bytes
	return "réseau: %d tuiles (%s) + %d cartes (%s) = %s en %d requêtes, %d échecs" % [
		net_tiles, human_bytes(net_tile_bytes), net_maps, human_bytes(net_map_bytes),
		human_bytes(total), net_requests, net_failed]


## Octets en unité lisible. Une tuile pèse ~1,4 Kio : afficher « 0.00 Mio » n'apprendrait
## rien, et c'est le volume réel que l'on cherche à voir.
static func human_bytes(n: int) -> String:
	if n < 1024:
		return "%d o" % n
	if n < 1048576:
		return "%.1f Kio" % (n / 1024.0)
	return "%.2f Mio" % (n / 1048576.0)

var _present: Dictionary = {}     # "n<nside>/f<shard>" -> PackedByteArray
var _misses: Dictionary = {}      # URL -> true, pour ne pas redemander un 404


## URL de base du service de tuiles, ou "" quand le streaming est éteint.
##
## Même idiome que PropNet.prof_on : ligne de commande, puis variable d'environnement,
## puis ini. C'est un réglage de DÉPLOIEMENT — il ne peut pas vivre dans une ressource de
## planète versionnée, puisqu'il diffère entre poste de dev, préprod et production.
##
## Éteint par défaut : sans lui, rien ne change pour les planètes qui lisent leur pack
## local, ce qui est le cas de toutes aujourd'hui.
static func configured_base_url() -> String:
	var args: PackedStringArray = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for a: String in args:
		if a.begins_with("--tile-stream="):
			return a.split("=", true, 1)[1]
	var env := OS.get_environment("DS_TILE_STREAM")
	if env != "":
		return env
	var ini: String = "server.ini" if OS.has_feature("dedicated_server") else "client.ini"
	for a: String in args:
		if a.contains("srvini="):
			ini = a.split("=")[1]
	var cfg := ConfigFile.new()
	if cfg.load(ini) != OK:
		return ""
	return str(cfg.get_value("stream", "tiles_url", ""))


## Construit une source prête à l'emploi pour cette planète, ou null.
##
## Null couvre les deux cas normaux : aucun service configuré, et service injoignable. Un
## service en panne ne doit pas empêcher de jouer — la planète retombe simplement sur son
## pack local, qui est le comportement d'aujourd'hui.
static func for_planet(planet_name: String) -> RemoteTileSource:
	var url := configured_base_url()
	if url == "" or planet_name == "":
		return null
	var src := RemoteTileSource.new()
	if not src.open_planet(url, planet_name):
		print("[RemoteTileSource] indisponible pour '%s' (%s) — pack local"
				% [planet_name, url])
		return null
	# Les objets d'une version sont immuables, donc jamais périmés : le changement de
	# version est le seul moment où l'on jette.
	var dropped := src.purge_other_versions()
	var budget := TileCacheLru.configured_budget_mb()
	if budget > 0:
		src.lru = TileCacheLru.new()
		src.lru.set_budget_mb(budget)
		src.lru.open("%s%s/%s/" % [src.cache_root, src.planet, src.version])
	src.start()
	# À l'approche de la planète, pas au menu : une requête, au moment où cela devient
	# utile. Sur le fil, donc sans jamais retarder l'affichage.
	if src.floor_nside_max > 0:
		src._enqueue(0, 0, JOB_FLOOR)
	print("[RemoteTileSource] '%s' version=%s tile_res=%d n%d..n%d%s%s"
			% [planet_name, src.version, src.tile_res, src.nside_min, src.nside_max,
			" (%d ancienne(s) version(s) purgée(s))" % dropped if dropped else "",
			"  %s" % src.lru.stat_line() if src.lru != null else "  cache non borné"])
	return src


## Lit le pointeur de version et s'auto-configure. Rend false si le service est injoignable
## ou répond autre chose que le pointeur attendu.
func open_planet(p_base_url: String, p_planet: String) -> bool:
	base_url = p_base_url.rstrip("/")
	planet = p_planet
	var res: Array = _request("%s/%s/latest.json" % [base_url, planet])
	if res[0] != 200:
		return false
	var parsed: Variant = JSON.parse_string((res[1] as PackedByteArray).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = parsed
	version = str(d.get("data_version", ""))
	tile_res = int(d.get("tile_res", 0))
	nside_min = int(d.get("nside_min", 1))
	nside_max = int(d.get("nside_max", 0))
	shard_tiles = int(d.get("shard_tiles", 4096))
	floor_nside_max = int(d.get("floor_nside_max", 0))
	return version != "" and tile_res > 0 and nside_max > 0


## Répertoire d'un shard, côté service.
func shard_url(nside: int, ipix: int) -> String:
	@warning_ignore("integer_division")
	var shard := ipix / shard_tiles
	return "%s/%s/%s/n%d/f%d" % [base_url, planet, version, nside, shard]


func tile_url(nside: int, ipix: int) -> String:
	return "%s/f%d.bin" % [shard_url(nside, ipix), ipix]


## Chemin du cache disque. La version en fait partie : purger une ancienne version est un
## simple effacement de répertoire, et deux versions ne peuvent pas se mélanger.
## Objet unique portant les niveaux grossiers. Une requête au lieu de ~1020.
func floor_url() -> String:
	return "%s/%s/%s/floor.bin" % [base_url, planet, version]


## Témoin de plancher déjà éclaté dans le cache. Dans le répertoire de version, donc un
## ré-export le laisse derrière lui avec le reste de l'ancienne version.
func floor_marker_path() -> String:
	return "%s%s/%s/floor.done" % [cache_root, planet, version]


func tile_cache_path(nside: int, ipix: int) -> String:
	@warning_ignore("integer_division")
	var shard := ipix / shard_tiles
	return "%s%s/%s/n%d/f%d/f%d.bin" % [cache_root, planet, version, nside, shard, ipix]


## Décode l'enveloppe de 12 octets posée par publish_tiles.py.
## Rend un tableau vide si la magie ou le CRC ne collent pas — c'est-à-dire si l'objet
## n'est pas une tuile (page d'erreur mise en cache) ou s'il est corrompu. TLS ne couvre
## ni l'un ni l'autre.
static func decode_envelope(blob: PackedByteArray) -> PackedByteArray:
	if blob.size() < TILE_HEADER:
		return PackedByteArray()
	if blob.decode_u32(0) != TILE_MAGIC:
		return PackedByteArray()
	var crc := blob.decode_u32(4)
	var flags := blob.decode_u32(8)
	var payload := blob.slice(TILE_HEADER)
	if _crc32(payload) != crc:
		return PackedByteArray()
	if (flags & FLAG_DEFLATE) != 0:
		# decompress() exige la taille attendue ; decompress_dynamic ne l'exige pas.
		return payload.decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE)
	return payload


## Présence SANS BLOQUER, pour le thread principal.
##
## [method has_tile] va chercher la carte du shard en HTTP synchrone si elle manque. Appelé
## depuis le thread principal pour chaque chunk en attente à chaque frame, cela a fait
## tomber le jeu à 0,2 FPS : des dizaines d'allers-retours réseau par image. Cette
## variante ne consulte que ce qui est déjà là, met la carte en file si elle manque, et
## rend UNKNOWN — à charge pour l'appelant de différer le chunk.
func presence_of(nside: int, ipix: int) -> int:
	@warning_ignore("integer_division")
	var shard := ipix / shard_tiles
	var key := "n%d/f%d" % [nside, shard]
	_mutex.lock()
	var bits: Variant = _present.get(key)
	_mutex.unlock()
	if bits == null:
		_enqueue(nside, shard * shard_tiles, JOB_PRESENCE)
		return PRESENCE_UNKNOWN
	var packed: PackedByteArray = bits
	var i := ipix - shard * shard_tiles
	var byte := i >> 3
	if byte >= packed.size():
		return PRESENCE_NO
	return PRESENCE_YES if ((packed[byte] >> (i & 7)) & 1) == 1 else PRESENCE_NO


## La tuile est-elle publiée ? Va chercher la carte du shard si elle manque, donc
## BLOQUANT : réservé au fil de téléchargement. Le thread principal utilise presence_of().
func has_tile(nside: int, ipix: int) -> bool:
	@warning_ignore("integer_division")
	var shard := ipix / shard_tiles
	var key := "n%d/f%d" % [nside, shard]
	_mutex.lock()
	var known: bool = _present.has(key)
	_mutex.unlock()
	if not known:
		var res: Array = _request("%s/present.bin" % shard_url(nside, ipix))
		if res[0] != 200:
			return false
		_mutex.lock()
		_present[key] = res[1]
		net_maps += 1
		net_map_bytes += (res[1] as PackedByteArray).size()
		_mutex.unlock()
	_mutex.lock()
	var bits: PackedByteArray = _present[key]
	_mutex.unlock()
	var i := ipix - shard * shard_tiles
	var byte := i >> 3
	if byte >= bits.size():
		return false
	return (bits[byte] >> (i & 7)) & 1 == 1


## Tuile depuis le cache disque, ou tableau vide. Ne déclenche AUCUN réseau.
func take(nside: int, ipix: int) -> PackedByteArray:
	var path := tile_cache_path(nside, ipix)
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var raw := f.get_buffer(f.get_length())
	f.close()
	if lru != null:
		lru.touch(nside, path)
	return decode_envelope(raw)


## Récupère la tuile et la met en cache. Bloquant : réservé au préchargement hors du
## chemin critique, jamais depuis une tâche de mesh.
func fetch_now(nside: int, ipix: int) -> bool:
	# Déjà en cache : le prefetch redemande volontiers ce qu'il a déjà, et sans ce test
	# chaque redemande re-téléchargerait la tuile.
	if FileAccess.file_exists(tile_cache_path(nside, ipix)):
		if lru != null:
			lru.touch(nside, tile_cache_path(nside, ipix))
		return true
	if not has_tile(nside, ipix):
		return false
	var url := tile_url(nside, ipix)
	if _misses.has(url):
		return false
	var res: Array = _request(url)
	if res[0] != 200:
		# Un 404 ici est une incohérence : la carte de présence l'annonçait. On le retient
		# pour ne pas boucler dessus, et il ressortira dans les compteurs.
		_misses[url] = true
		net_failed += 1
		return false
	if decode_envelope(res[1]).is_empty():
		_misses[url] = true
		net_failed += 1
		return false
	net_tiles += 1
	net_tile_bytes += (res[1] as PackedByteArray).size()
	var path := tile_cache_path(nside, ipix)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(res[1])
	f.close()
	if lru != null:
		lru.admit(nside, path)
	return true


## Récupère le plancher et l'éclate dans le cache. Bloquant : fil de téléchargement seul.
##
## Les niveaux grossiers ne servent pas au sol — mesuré sur une session réelle, 9 % d'entre
## eux sont lus — mais à la planète vue de loin, dont on balaye toute la sphère. Les
## demander une par une coûte ~1020 allers-retours, soit des minutes sur un vrai réseau
## pour 1,9 Mio ; ici c'est une requête, au moment où l'on approche de la planète.
##
## Rend le nombre de tuiles écrites. 0 couvre aussi bien « déjà fait » que « pas de
## plancher servi » : dans les deux cas il n'y a rien à faire et les tuiles isolées
## restent le chemin de repli.
func fetch_floor() -> int:
	if floor_nside_max <= 0 or FileAccess.file_exists(floor_marker_path()):
		return 0
	var res: Array = _request(floor_url())
	if res[0] != 200:
		net_failed += 1
		return 0
	var blob: PackedByteArray = res[1]
	var entries := decode_floor(blob)
	if entries.is_empty():
		net_failed += 1
		return 0
	net_maps += 1
	net_map_bytes += blob.size()
	var n := 0
	for e: Dictionary in entries:
		var path := tile_cache_path(e["nside"], e["ipix"])
		if FileAccess.file_exists(path):
			continue
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			continue
		f.store_buffer(e["blob"])
		f.close()
		n += 1
	# Le témoin n'est posé qu'une fois tout écrit : un arrêt en cours de route se
	# retraduit par un nouveau téléchargement, pas par un plancher à trous.
	DirAccess.make_dir_recursive_absolute(floor_marker_path().get_base_dir())
	var m := FileAccess.open(floor_marker_path(), FileAccess.WRITE)
	if m != null:
		m.store_string("%d" % entries.size())
		m.close()
	return n


## Index du plancher, ou tableau vide si l'objet n'en est pas un.
##
## Les charges utiles sont les octets EXACTEMENT servis pour une tuile isolée : on les
## écrit tels quels dans le cache, sans les décoder. Un plancher et une tuile ne peuvent
## donc pas diverger, et le CRC de chacune sera vérifié à la lecture comme d'habitude.
static func decode_floor(blob: PackedByteArray) -> Array:
	if blob.size() < FLOOR_HEADER:
		return []
	if blob.decode_u32(0) != FLOOR_MAGIC or blob.decode_u32(4) != 1:
		return []
	var count := blob.decode_u32(8)
	if FLOOR_HEADER + count * FLOOR_ENTRY > blob.size():
		return []
	var out: Array = []
	for k in count:
		var at := FLOOR_HEADER + k * FLOOR_ENTRY
		var off := blob.decode_u32(at + 8)
		var length := blob.decode_u32(at + 12)
		if off + length > blob.size():
			return []
		out.append({
			"nside": blob.decode_u32(at),
			"ipix": blob.decode_u32(at + 4),
			"blob": blob.slice(off, off + length),
		})
	return out


## Supprime du cache toutes les versions de cette planète sauf celle en cours.
## Le changement de version est le seul moment où l'on jette : les objets d'une version
## donnée sont immuables, donc jamais périmés.
func purge_other_versions() -> int:
	var root := "%s%s/" % [cache_root, planet]
	var d := DirAccess.open(root)
	if d == null:
		return 0
	var removed := 0
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if d.current_is_dir() and name != version:
			_remove_tree(root + name)
			removed += 1
		name = d.get_next()
	d.list_dir_end()
	return removed


## Démarre le fil de téléchargement. Idempotent.
func start() -> void:
	if _thread != null:
		return
	_quit = false
	_thread = Thread.new()
	_thread.start(_worker)


## Arrête le fil et l'attend. À appeler avant de libérer la source.
func stop() -> void:
	if _thread == null:
		return
	_mutex.lock()
	_quit = true
	_mutex.unlock()
	_sem.post()
	_thread.wait_to_finish()
	_thread = null
	if lru != null:
		lru.save()


## Met une tuile en file. Ne bloque pas et ne redemande jamais deux fois la même.
## Sans effet si la tuile est déjà en cache ou si la carte de présence la nie.
func queue(nside: int, ipix: int) -> void:
	_enqueue(nside, ipix, JOB_TILE)


func _enqueue(nside: int, ipix: int, kind: int) -> void:
	var key := "%d/%d/%d" % [kind, nside, ipix]
	_mutex.lock()
	var known: bool = _queued.has(key)
	if not known:
		_queued[key] = true
		_queue.append(Vector3i(ipix, nside, kind))
		if kind == JOB_TILE:
			stat_requested += 1
	_mutex.unlock()
	if not known:
		_sem.post()


## Oublie qu'un travail était en file, une fois traité.
##
## _queued ne sert qu'à ne pas mettre deux fois le même travail en attente ; le garder
## indéfiniment en ferait un index de toutes les tuiles jamais demandées — plus d'un
## million d'entrées sur tarsis_3. Redemander est sans conséquence : fetch_now sort
## immédiatement quand la tuile est déjà en cache.
func _forget(kind: int, nside: int, ipix: int) -> void:
	_mutex.lock()
	_queued.erase("%d/%d/%d" % [kind, nside, ipix])
	_mutex.unlock()


func _worker() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		if _quit:
			_mutex.unlock()
			return
		var item: Vector3i = _queue.pop_front() if not _queue.is_empty() else Vector3i(-1, -1, 0)
		_mutex.unlock()
		if item.x < 0:
			continue
		if item.z == JOB_FLOOR:
			fetch_floor()
			_forget(item.z, item.y, item.x)
			continue
		if item.z == JOB_PRESENCE:
			# Rapatrie la carte du shard. C'est ce qui débloque presence_of() côté
			# thread principal, sans que celui-ci n'ait jamais touché au réseau.
			has_tile(item.y, item.x)
			_forget(item.z, item.y, item.x)
			continue
		var ok := fetch_now(item.y, item.x)
		_mutex.lock()
		if ok:
			stat_fetched += 1
		else:
			stat_failed += 1
		_mutex.unlock()
		_forget(item.z, item.y, item.x)


func _request(url: String) -> Array:
	if fetcher.is_valid():
		return fetcher.call(url)
	return _http_get(url)


## Chemin par défaut. Synchrone : réservé au fil de téléchargement, jamais au thread
## principal. La connexion est [b]conservée[/b] d'une tuile à l'autre.
##
## Sur loopback le gain est modeste — mesuré sur nginx en local, 200 tuiles en 0,55 ms
## l'une avec une connexion neuve à chaque fois contre 0,43 ms en la conservant, soit
## 1,3×. Une poignée de main TCP y est quasi gratuite. Ce que la connexion conservée
## économise vraiment, c'est un aller-retour complet par tuile dès qu'il y a de la latence
## (davantage encore en TLS, où l'établissement coûte deux à trois RTT). Le prefetch en
## anneau demandant des dizaines de tuiles par déplacement, cela se voit sur un vrai
## réseau et jamais sur la machine de développement — d'où cette note.
func _http_get(url: String) -> Array:
	var parts := url.split("://", true, 1)
	var rest: String = parts[1] if parts.size() > 1 else parts[0]
	var slash := rest.find("/")
	var host: String = rest.substr(0, slash) if slash >= 0 else rest
	var path: String = rest.substr(slash) if slash >= 0 else "/"
	var port := 80
	if host.contains(":"):
		var hp := host.split(":")
		host = hp[0]
		port = int(hp[1])
	# Une seule reprise : le serveur a le droit de fermer une connexion inactive, et cela
	# ne doit pas se traduire par une tuile manquante.
	var res := _http_once(host, port, path)
	if res[0] == 0:
		_conn = null
		res = _http_once(host, port, path)
	return res


## Une requête sur la connexion courante, qu'elle rouvre si besoin. [0, vide] signale une
## connexion inutilisable — à l'appelant de réessayer une fois.
func _http_once(host: String, port: int, path: String) -> Array:
	if _conn == null or _conn_host != host or _conn_port != port \
			or _conn.get_status() != HTTPClient.STATUS_CONNECTED:
		_conn = HTTPClient.new()
		_conn_host = host
		_conn_port = port
		if _conn.connect_to_host(host, port) != OK:
			_conn = null
			return [0, PackedByteArray()]
		while _conn.get_status() == HTTPClient.STATUS_CONNECTING \
				or _conn.get_status() == HTTPClient.STATUS_RESOLVING:
			_conn.poll()
		if _conn.get_status() != HTTPClient.STATUS_CONNECTED:
			_conn = null
			return [0, PackedByteArray()]
	if _conn.request(HTTPClient.METHOD_GET, path, []) != OK:
		return [0, PackedByteArray()]
	while _conn.get_status() == HTTPClient.STATUS_REQUESTING:
		_conn.poll()
	var code := _conn.get_response_code()
	if code == 0:
		return [0, PackedByteArray()]
	var body := PackedByteArray()
	while _conn.get_status() == HTTPClient.STATUS_BODY:
		_conn.poll()
		body.append_array(_conn.read_response_body_chunk())
	net_requests += 1
	return [code, body]


static func _remove_tree(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if d.current_is_dir():
			_remove_tree(path.path_join(name))
		else:
			d.remove(path.path_join(name))
		name = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)


## CRC32 (polynôme IEEE réfléchi), le même que zlib.crc32 côté publieur.
## Godot n'expose pas de CRC32, et l'octet de travers que ce contrôle attrape ne se
## verrait autrement qu'en jeu, sous la forme d'un relief faux.
static var _crc_table: PackedInt64Array = _build_crc_table()


static func _build_crc_table() -> PackedInt64Array:
	var t := PackedInt64Array()
	t.resize(256)
	for i in 256:
		var c := i
		for _k in 8:
			c = (0xEDB88320 ^ (c >> 1)) if (c & 1) != 0 else (c >> 1)
		t[i] = c
	return t


static func _crc32(data: PackedByteArray) -> int:
	var c := 0xFFFFFFFF
	for i in data.size():
		c = _crc_table[(c ^ data[i]) & 0xFF] ^ (c >> 8)
	return c ^ 0xFFFFFFFF
