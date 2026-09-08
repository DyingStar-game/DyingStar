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
## Racine du cache disque. Chaque version a son sous-répertoire, donc changer de version
## n'invalide rien : on écrit ailleurs et on supprime les anciennes.
var cache_root: String = "user://tile_cache/"
## Callable(url) -> [code:int, body:PackedByteArray].
var fetcher: Callable = Callable()

## Fil de téléchargement. Le chemin d'échantillonnage tourne sur WorkerThreadPool ; y
## attendre une socket gèlerait la génération de terrain. Les demandes sont donc mises en
## file et servies ici, pendant que l'appelant diffère le chunk concerné.
var _thread: Thread = null
var _queue: Array[Vector2i] = []      # (ipix, nside)
var _queued: Dictionary = {}          # "n/p" -> true, pour ne pas redemander
var _mutex: Mutex = Mutex.new()
var _sem: Semaphore = Semaphore.new()
var _quit: bool = false
## Compteurs, lus par le profilage : ce qui a été demandé, servi, refusé.
var stat_requested: int = 0
var stat_fetched: int = 0
var stat_failed: int = 0

var _present: Dictionary = {}     # "n<nside>/f<shard>" -> PackedByteArray
var _misses: Dictionary = {}      # URL -> true, pour ne pas redemander un 404


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


## La tuile est-elle publiée ? Répond depuis la carte de présence du shard, qui couvre
## 4096 tuiles voisines pour 512 octets.
##
## Sans elle, une tuile absente ne se découvrirait que par un 404 : deux allers-retours sur
## la majorité des requêtes, puisque 35 à 65 % des tuiles d'un pack creux n'existent pas.
func has_tile(nside: int, ipix: int) -> bool:
	@warning_ignore("integer_division")
	var shard := ipix / shard_tiles
	var key := "n%d/f%d" % [nside, shard]
	if not _present.has(key):
		var res: Array = _request("%s/present.bin" % shard_url(nside, ipix))
		if res[0] != 200:
			return false
		_present[key] = res[1]
	var bits: PackedByteArray = _present[key]
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
	return decode_envelope(raw)


## Récupère la tuile et la met en cache. Bloquant : réservé au préchargement hors du
## chemin critique, jamais depuis une tâche de mesh.
func fetch_now(nside: int, ipix: int) -> bool:
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
		return false
	if decode_envelope(res[1]).is_empty():
		_misses[url] = true
		return false
	var path := tile_cache_path(nside, ipix)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(res[1])
	f.close()
	return true


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


## Met une tuile en file. Ne bloque pas et ne redemande jamais deux fois la même.
## Sans effet si la tuile est déjà en cache ou si la carte de présence la nie.
func queue(nside: int, ipix: int) -> void:
	var key := "%d/%d" % [nside, ipix]
	_mutex.lock()
	var known: bool = _queued.has(key)
	if not known:
		_queued[key] = true
		_queue.append(Vector2i(ipix, nside))
		stat_requested += 1
	_mutex.unlock()
	if not known:
		_sem.post()


func _worker() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		if _quit:
			_mutex.unlock()
			return
		var item: Vector2i = _queue.pop_front() if not _queue.is_empty() else Vector2i(-1, -1)
		_mutex.unlock()
		if item.x < 0:
			continue
		var ok := fetch_now(item.y, item.x)
		_mutex.lock()
		if ok:
			stat_fetched += 1
		else:
			stat_failed += 1
		_mutex.unlock()


func _request(url: String) -> Array:
	if fetcher.is_valid():
		return fetcher.call(url)
	return _http_get(url)


func _http_get(url: String) -> Array:
	# Chemin par défaut. Volontairement simple et synchrone : il ne sert qu'au
	# préchargement hors chemin critique. La mise en file non bloquante viendra par-dessus.
	var http := HTTPClient.new()
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
	if http.connect_to_host(host, port) != OK:
		return [0, PackedByteArray()]
	while http.get_status() == HTTPClient.STATUS_CONNECTING \
			or http.get_status() == HTTPClient.STATUS_RESOLVING:
		http.poll()
	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		return [0, PackedByteArray()]
	if http.request(HTTPClient.METHOD_GET, path, []) != OK:
		return [0, PackedByteArray()]
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
	var code := http.get_response_code()
	var body := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		body.append_array(http.read_response_body_chunk())
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
