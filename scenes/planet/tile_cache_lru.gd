class_name TileCacheLru
extends RefCounted
## Borne le cache disque de tuiles de hauteur, par éviction du moins récemment utilisé.
##
## Sans cela le cache grossit sans limite — et le prefetch en anneau le remplit bien plus
## vite que les demandes à la carte qu'il a remplacées.
##
## [b]Le budget se compte en TUILES, pas en octets.[/b] Mesuré sur l'export tarsis_3 n256 :
## 674 884 tuiles, 849 Mio de données mais 2,6 Gio sur disque. Aucune tuile n'atteint 4 Kio
## (max 2060 o, médiane 1383 o), donc chacune occupe exactement un bloc de système de
## fichiers. Un budget exprimé en octets de données consommerait donc trois fois ce qu'il
## annonce ; on convertit une fois, ici, et on raisonne ensuite en nombre de fichiers.
##
## Les niveaux grossiers sont [b]épinglés[/b] plutôt que gérés en LRU : une tuile n16
## couvre 407 km de côté (12,7 km par échantillon) et sert des milliers de chunks, la
## faire évincer par un déplacement au sol serait absurde. n1…n16, c'est la planète
## entière pour 16 Mio, et une vue orbitale n'émet alors aucune requête.

## Coût disque d'une tuile. Voir plus haut : aucune ne dépasse un bloc.
const BLOCK_BYTES := 4096

## Budget par défaut, en mébioctets de disque (1 Mio = 1024 Kio).
##
## C'est un plafond, pas une cible : une session de jeu réelle mesurée sur l'export n256
## tient dans 2,2 Mio (535 tuiles), et la même session à la résolution visée n1024 en
## demanderait 2 095, soit 8,2 Mio. Le budget vaut donc seize fois la session la plus
## lourde qu'on ait mesurée. Il n'est jamais réservé — il ne coûte rien tant qu'il n'est
## pas atteint — et n'existe que pour le cas pathologique du joueur qui survole la planète
## des heures durant. Il reste sous un vingtième de la planète complète, si bien que le
## cache ne peut pas dégénérer en « télécharger la planète ».
const DEFAULT_BUDGET_MB := 128

## Dernier niveau épinglé, jamais évincé. n16 = 4095 tuiles = 16 Mio pour la planète entière.
const PIN_NSIDE_MAX := 16

## On purge jusqu'à cette fraction du budget plutôt que jusqu'au budget, pour ne pas
## relancer une éviction à chaque tuile écrite ensuite.
const EVICT_TO := 0.9

@warning_ignore("integer_division")
var budget_tiles: int = DEFAULT_BUDGET_MB * 1024 * 1024 / BLOCK_BYTES
var pin_nside_max: int = PIN_NSIDE_MAX

## Chemin relatif à [member dir] → date d'usage. Ne contient que les tuiles évinçables.
var _use: Dictionary = {}
var _tick: int = 0
var _dir: String = ""
var _mutex := Mutex.new()
var _dirty: bool = false

## Nombre de tuiles supprimées depuis l'ouverture — pour le compteur de diagnostic.
var stat_evicted: int = 0

## Reflet statique du cache en cours, pour que le profileur puisse l'afficher sans avoir à
## remonter jusqu'à la planète. Même motif que les compteurs réseau de RemoteTileSource.
static var live: TileCacheLru = null


## Budget configuré, en mébioctets. Même cascade que le reste du streaming :
## --tile-cache-mb=, puis DS_TILE_CACHE_MB, puis [stream] tile_cache_mb du .ini.
## 0 désactive l'éviction.
static func configured_budget_mb() -> int:
	var args: PackedStringArray = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for a: String in args:
		if a.begins_with("--tile-cache-mb="):
			return maxi(int(a.split("=", true, 1)[1]), 0)
	var env := OS.get_environment("DS_TILE_CACHE_MB")
	if env != "":
		return maxi(int(env), 0)
	var ini: String = "server.ini" if OS.has_feature("dedicated_server") else "client.ini"
	for a: String in args:
		if a.contains("srvini="):
			ini = a.split("=")[1]
	var cfg := ConfigFile.new()
	if cfg.load(ini) != OK:
		return DEFAULT_BUDGET_MB
	return maxi(int(cfg.get_value("stream", "tile_cache_mb", DEFAULT_BUDGET_MB)), 0)


@warning_ignore("integer_division")
func set_budget_mb(mb: int) -> void:
	budget_tiles = mb * 1024 * 1024 / BLOCK_BYTES


## Prend en charge un répertoire de cache déjà peuplé.
##
## L'index rend l'ordre d'usage de la session précédente. Quand il manque — premier
## lancement, ou arrêt brutal — on se rabat sur un parcours du répertoire : l'ordre est
## alors inconnu et la première éviction sera arbitraire, mais le budget reste tenu, ce
## qui est la propriété qui compte.
func open(p_dir: String) -> void:
	_dir = p_dir if p_dir.ends_with("/") else p_dir + "/"
	_use.clear()
	_tick = 0
	if not _load_index():
		_scan(_dir, "")
	for t: int in _use.values():
		_tick = maxi(_tick, t + 1)
	live = self


## Signale qu'une tuile vient d'être lue depuis le cache.
func touch(nside: int, path: String) -> void:
	if nside <= pin_nside_max:
		return
	_mutex.lock()
	_use[path.trim_prefix(_dir)] = _tick
	_tick += 1
	_dirty = true
	_mutex.unlock()


## Signale qu'une tuile vient d'être écrite, et évince si le budget est dépassé.
## Rend le nombre de fichiers supprimés.
func admit(nside: int, path: String) -> int:
	touch(nside, path)
	if nside <= pin_nside_max or budget_tiles <= 0:
		return 0
	_mutex.lock()
	var over: bool = _use.size() > budget_tiles
	_mutex.unlock()
	return _evict() if over else 0


## Supprime les plus anciennes jusqu'à EVICT_TO du budget.
func _evict() -> int:
	_mutex.lock()
	var keys: Array = _use.keys()
	var target: int = int(budget_tiles * EVICT_TO)
	var drop: int = keys.size() - target
	if drop <= 0:
		_mutex.unlock()
		return 0
	keys.sort_custom(func(a: String, b: String) -> bool: return _use[a] < _use[b])
	var doomed: Array = keys.slice(0, drop)
	for k: String in doomed:
		_use.erase(k)
	stat_evicted += doomed.size()
	_dirty = true
	_mutex.unlock()
	# Hors verrou : l'effacement disque ne doit pas bloquer le thread principal, qui
	# consulte le cache pendant ce temps.
	for k: String in doomed:
		DirAccess.remove_absolute(_dir + k)
	return doomed.size()


## Nombre de tuiles évinçables actuellement suivies.
func size() -> int:
	_mutex.lock()
	var n: int = _use.size()
	_mutex.unlock()
	return n


func index_path() -> String:
	return _dir + "index.bin"


## Écrit l'index si quelque chose a changé. Appelé à l'arrêt de la source.
func save() -> void:
	if _dir == "" or not _dirty:
		return
	var f := FileAccess.open(index_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_var(_use)
	f.close()
	_dirty = false


func _load_index() -> bool:
	if not FileAccess.file_exists(index_path()):
		return false
	var f := FileAccess.open(index_path(), FileAccess.READ)
	if f == null:
		return false
	var v: Variant = f.get_var()
	f.close()
	if typeof(v) != TYPE_DICTIONARY:
		return false
	_use = v
	return true


## Parcourt le cache pour retrouver les tuiles évinçables, quand l'index manque.
func _scan(dir: String, rel: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub: String in d.get_directories():
		# Les niveaux épinglés ne sont pas suivis : ils ne sont jamais candidats.
		if sub.begins_with("n") and sub.substr(1).is_valid_int() \
				and int(sub.substr(1)) <= pin_nside_max:
			continue
		_scan(dir + sub + "/", rel + sub + "/")
	for file: String in d.get_files():
		# index.bin porte l'extension des tuiles mais n'en est pas une : la suivre
		# reviendrait à s'auto-évincer.
		if file.ends_with(".bin") and rel + file != "index.bin":
			_use[rel + file] = 0


func stat_line() -> String:
	var mb := float(size()) * BLOCK_BYTES / 1048576.0
	var budget_mb := float(budget_tiles) * BLOCK_BYTES / 1048576.0
	return "cache tuiles: %d fichiers, %.1f / %.0f Mio disque, %d évincées" \
			% [size(), mb, budget_mb, stat_evicted]


## Ligne du cache en cours, ou vide s'il n'y en a pas. Pour TerrainProfiler.
static func live_line() -> String:
	return live.stat_line() if live != null else ""
