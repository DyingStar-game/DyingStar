class_name StarMapTiles
extends RefCounted
## Where the chart reads one body's heights from, and the memory it keeps them in.
##
## Two sources, one answer. When the body is LOADED — the player is on it or near it — its [PlanetData]
## already holds exactly what the chart needs: a thread-safe float32 cache of the same tiles, filled from
## the local heights.pack and then from the streamed disk cache, in the same units. Reading anything else
## would decode every tile a second time into a second cache, and ignore the pack altogether. When it is
## not loaded, the tiles come off the disk cache through a read-only [RemoteTileSource], into a small
## LRU kept here and shared by every reader of that body and version.
##
## Before this existed each tile build opened its own source and read, unwrapped and widened its tiles
## from disk every time — including the ANCESTOR a provisional tile is cut from, which one n16 tile
## under a view at n256 meant reading and decoding the same file for each of hundreds of descendants.
##
## ⚠️ Made on the MAIN thread only ([method for_body]): finding the live planet goes through the network
## registry, which is not something a worker may walk. Once made, a reader is safe to use from workers.

## What the disk-side cache may hold. A 32² tile is 4 KB of floats, so this is some sixteen thousand
## tiles — forty views' worth at [constant StarMapRelief.PATCH_TILES_MAX].
const BUDGET_BYTES: int = 64 * 1024 * 1024
## How long a body with nothing on disk is believed to have nothing, before the disk is looked at again.
const NO_VERSION_RETRY_MS: int = 2000

var body_key: String = ""
## The body's [PlanetData]: the live planet's when it is loaded, otherwise the chart's own copy of the
## one in the body's scene ([method offline_data]). Null when neither can be had. It is what the ground
## is SAMPLED through — the game's own sampler, so the chart draws the ground you will land on.
## A reader holds the live one only for as long as it exists: readers are made per frame and per
## build, never kept, so a planet that unloads is not kept alive by the chart.
var data: PlanetData = null
## Read-only disk source; never started, never given a url. Null when nothing is on disk. Asked only for
## what [member data] does not have, when there is a [member data].
var source: RemoteTileSource = null

static var _mutex: Mutex = Mutex.new()
## "body/version" -> {tile id: PackedFloat32Array}
static var _floats: Dictionary = {}
## "body/version" -> {tile id: last use}
static var _ticks: Dictionary = {}
static var _seq: int = 0
static var _bytes: int = 0

## body -> {"version": String, "at": msec}. The version on disk, looked up once rather than listing a
## directory every frame, which is what has_data() used to do sixty times a second.
static var _versions: Dictionary = {}
## body -> RemoteTileSource, the read-only probes. One per body and version.
static var _sources: Dictionary = {}
## The per-frame memo of [method for_body]: resolving a live planet walks the registry, and the height
## field is asked about thousands of directions a frame when the roads are laid.
static var _frame: int = -1
static var _frame_readers: Dictionary = {}
## body -> {"data": PlanetData or null, "at": msec}: the chart's own PlanetData for a body that is not
## loaded, prepared once. A null is looked at again after [constant NO_VERSION_RETRY_MS], like a missing
## version: the tiles it needs may not have landed yet.
static var _offline: Dictionary = {}

## What reading heights costs, against what building a tile costs: name -> count or microseconds.
## Kept only while [constant StarMapGround.DEBUG_GROUND] is on — off, a call pays one constant test.
##
## Here to settle one question on a figure rather than an argument: is it worth aligning the chart's
## levels with the planet's quadtree so that it finds more of its tiles in the planet's cache? Only if
## reading is a real share of a build. The kinds of read, per call to [method heights]:
##   planet_hit   already in the loaded planet's cache
##   planet_load  not there; the planet read it (pack or disk) into its cache
##   memo_hit     in this file's own cache (body not loaded)
##   disk_read    read and decoded from the disk cache by this file
##   miss         nowhere; the walk goes on to the ancestor
static var _stats: Dictionary = {}


## The reader for [param key], resolved now. Main thread only.
static func for_body(key: String) -> StarMapTiles:
	var frame: int = Engine.get_process_frames()
	if frame != _frame:
		_frame = frame
		_frame_readers.clear()
	if _frame_readers.has(key):
		return _frame_readers[key]
	var made := StarMapTiles.new()
	made.body_key = key
	var live: Planet = PlanetRegistry.find_by_name(key) if key != "" else null
	if live != null and live.planet_data != null and live.planet_data.chunk_heightmaps_dir != "":
		made.data = live.planet_data
	# The disk as well, for what the planet does not hold: a local pack may start below the floor's
	# levels, and the chart's whole-globe view is drawn from exactly those.
	made.source = disk_source(key)
	if made.data == null:
		made.data = offline_data(key)
	_frame_readers[key] = made
	return made


## A reader that only ever looks at the disk: what a worker gets when nobody resolved one for it, and
## what a test gets, since no planet is loaded there.
static func on_disk(key: String) -> StarMapTiles:
	var made := StarMapTiles.new()
	made.body_key = key
	made.source = disk_source(key)
	return made


## Is there anything to read at all?
func usable() -> bool:
	return data != null or source != null


## The decoded heights of one tile, 0..1 as published, or empty when this tile is not to be had here.
## Safe from any thread.
func heights(nside: int, ipix: int) -> PackedFloat32Array:
	if not StarMapGround.DEBUG_GROUND:
		return _heights(nside, ipix)
	var started: int = Time.get_ticks_usec()
	var key: String = "hp_n%d_p%d" % [nside, ipix]
	var kind: String = ""
	if data != null and data.is_chunk_cached(key):
		kind = "planet_hit"
	elif data == null and _in_memo(nside, ipix):
		kind = "memo_hit"
	var out: PackedFloat32Array = _heights(nside, ipix)
	if kind == "":
		if out.is_empty():
			kind = "miss"
		elif data != null and data.is_chunk_cached(key):
			kind = "planet_load"
		else:
			kind = "disk_read"
	stat_add(kind, 1)
	stat_add(kind + "_us", Time.get_ticks_usec() - started)
	return out


func _in_memo(nside: int, ipix: int) -> bool:
	if source == null:
		return false
	_mutex.lock()
	var known: Dictionary = _floats.get("%s/%s" % [body_key, source.version], {})
	var found: bool = known.has(StarMapGround.tile_id(nside, ipix))
	_mutex.unlock()
	return found


func _heights(nside: int, ipix: int) -> PackedFloat32Array:
	if data != null:
		var held: PackedFloat32Array = data.load_chunk_floats(ipix, nside)
		if not held.is_empty():
			return held
	if source == null:
		return PackedFloat32Array()
	var bucket: String = "%s/%s" % [body_key, source.version]
	var id: int = StarMapGround.tile_id(nside, ipix)
	_mutex.lock()
	var known: Dictionary = _floats.get(bucket, {})
	if known.has(id):
		_seq += 1
		(_ticks[bucket] as Dictionary)[id] = _seq
		var hit: PackedFloat32Array = known[id]
		_mutex.unlock()
		return hit
	_mutex.unlock()
	# Read outside the lock: it is disk work, and two threads reading the same tile at worst decode it
	# twice.
	var raw: PackedByteArray = source.take(nside, ipix)
	var side: int = int(round(sqrt(float(raw.size()) / 2.0)))
	if side <= 1 or side * side * 2 != raw.size():
		return PackedFloat32Array()  # absent or malformed; NOT remembered, since it may yet arrive
	var out: PackedFloat32Array = HeightPack.widen_u16(raw, side).to_float32_array()
	_mutex.lock()
	if not _floats.has(bucket):
		_floats[bucket] = {}
		_ticks[bucket] = {}
	var bucket_floats: Dictionary = _floats[bucket]
	if not bucket_floats.has(id):
		bucket_floats[id] = out
		_bytes += out.size() * 4
	_seq += 1
	(_ticks[bucket] as Dictionary)[id] = _seq
	if _bytes > BUDGET_BYTES:
		_evict_locked()
	_mutex.unlock()
	return out


## Is this tile's OWN data here, as opposed to only an ancestor's? Main thread in practice.
func has_own(nside: int, ipix: int) -> bool:
	if data != null and not data.load_chunk_floats(ipix, nside).is_empty():
		return true
	if source == null:
		return false
	return FileAccess.file_exists(source.tile_cache_path(nside, ipix))


## The read-only source for what is on disk for [param key], or null. Remembered per body; a body
## with nothing on disk is looked at again only after [constant NO_VERSION_RETRY_MS].
static func disk_source(key: String) -> RemoteTileSource:
	var version: String = cached_version(key)
	if version == "":
		return null
	_mutex.lock()
	var made: RemoteTileSource = _sources.get(key)
	if made == null or made.version != version:
		# cache_root and shard_tiles keep their defaults; no thread is started and no url is set, so
		# this object can only ever read files.
		made = RemoteTileSource.new()
		made.planet = key
		made.version = version
		_sources[key] = made
	_mutex.unlock()
	return made


## Which version of [param key] is on disk, "" for none. See [method StarMapRelief._cached_version]
## for why the disk and not the channel.
static func cached_version(key: String) -> String:
	if key == "":
		return ""
	var now: int = Time.get_ticks_msec()
	_mutex.lock()
	var memo: Dictionary = _versions.get(key, {})
	_mutex.unlock()
	if not memo.is_empty():
		var version: String = str(memo["version"])
		# A version found is kept for good: a new one is only ever installed by a tile service that
		# purges the old, and the chart's own stream is what would do that, through [method forget].
		if version != "" or now < int(memo["at"]) + NO_VERSION_RETRY_MS:
			return version
	var found: String = StarMapRelief._cached_version(key)
	_mutex.lock()
	_versions[key] = {"version": found, "at": now}
	_mutex.unlock()
	return found


## A [PlanetData] for a body that is NOT loaded, set up the way [PlanetTerrain] sets up its own for
## everything a HEIGHT depends on: the chunk manifest, the tiles, the procedural mountains. Main thread
## only — warming the mountains is, and the result is then read from the workers as the game's is.
##
## Taken from the body's scene file and DUPLICATED. The scene's resource may be the very object a
## planet instanced from that scene uses, and this one gets a read-only disk source and a manifest of
## its own. What a height does not depend on — bridges, graded lines, pads, queries — is left cold:
## the chart samples the relief, it does not carve it.
##
## Null for a body with no PlanetData in its scene, no manifest, or nothing on disk yet.
static func offline_data(key: String) -> PlanetData:
	if key == "":
		return null
	var now: int = Time.get_ticks_msec()
	var memo: Dictionary = _offline.get(key, {})
	if not memo.is_empty() and (memo["data"] != null or now < int(memo["at"]) + NO_VERSION_RETRY_MS):
		return memo["data"]
	var made: PlanetData = _prepare_offline(key)
	_offline[key] = {"data": made, "at": now}
	return made


static func _prepare_offline(key: String) -> PlanetData:
	var source: RemoteTileSource = disk_source(key)
	if source == null:
		return null
	var props: Dictionary = SystemScenes.body_properties(StarMap.SYSTEM, key)
	var scene_data: PlanetData = props.get("planet_data") as PlanetData
	if scene_data == null:
		return null
	var made: PlanetData = scene_data.duplicate(true) as PlanetData
	if made.chunk_heightmaps_dir == "":
		made.chunk_heightmaps_dir = "%s/%s_chunks" % [StarMapRelief.EXPORT_ROOT, key]
	if not made.apply_chunk_manifest():
		return null
	made.remote_source = source
	made.warm_mountains()
	return made


## Look at the disk again for [param key]: its tile service has just (re)opened and may have installed a
## new version and purged the old.
static func forget(key: String) -> void:
	_mutex.lock()
	_versions.erase(key)
	_sources.erase(key)
	_frame_readers.erase(key)
	_offline.erase(key)
	_mutex.unlock()


## Drop the least recently used quarter. One sort per eviction rather than a scan per insertion.
static func _evict_locked() -> void:
	var order: Array = []
	for bucket: String in _ticks:
		var ticks: Dictionary = _ticks[bucket]
		for id: int in ticks:
			order.append([int(ticks[id]), bucket, id])
	order.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	@warning_ignore("integer_division")
	var target: int = BUDGET_BYTES * 3 / 4
	for entry: Array in order:
		if _bytes <= target:
			break
		var bucket: String = entry[1]
		var id: int = entry[2]
		var floats: PackedFloat32Array = (_floats[bucket] as Dictionary)[id]
		_bytes -= floats.size() * 4
		(_floats[bucket] as Dictionary).erase(id)
		(_ticks[bucket] as Dictionary).erase(id)


# ---------------------------------------------------------------------------
# Measuring
# ---------------------------------------------------------------------------

static func stat_add(name: String, amount: int) -> void:
	_mutex.lock()
	_stats[name] = int(_stats.get(name, 0)) + amount
	_mutex.unlock()


## A copy of the counters, taken under the lock: workers are writing them.
static func stats() -> Dictionary:
	_mutex.lock()
	var copy: Dictionary = _stats.duplicate()
	_mutex.unlock()
	return copy


static func reset_stats() -> void:
	_mutex.lock()
	_stats.clear()
	_mutex.unlock()


## The counters as one log line. Pure, so the arithmetic can be checked without building anything.
##
## The figure to read is the share of a build spent reading heights: that is the most aligning the
## chart's levels on the planet's could ever save.
static func stats_line(stats: Dictionary) -> String:
	var tiles: int = int(stats.get("tiles", 0))
	if tiles <= 0:
		return "aucune tuile construite"
	var read_us: int = int(stats.get("read_us", 0))
	var total_us: int = read_us + int(stats.get("build_us", 0))
	var kinds: PackedStringArray = []
	var calls: int = 0
	for kind: String in ["planet_hit", "planet_load", "memo_hit", "disk_read", "miss"]:
		calls += int(stats.get(kind, 0))
	for kind: String in ["planet_hit", "planet_load", "memo_hit", "disk_read", "miss"]:
		var n: int = int(stats.get(kind, 0))
		if n > 0:
			kinds.append("%s %d%% (%d, %.0f us moy.)" % [kind, roundi(100.0 * n / maxf(calls, 1)), n,
					float(stats.get(kind + "_us", 0)) / float(n)])
	return "%d tuiles, %d provisoires | %.2f ms/tuile dont lecture %.3f ms (%.1f %%) | lectures : %s" % [
		tiles, int(stats.get("provisional", 0)),
		total_us / 1000.0 / tiles, read_us / 1000.0 / tiles,
		100.0 * read_us / maxf(total_us, 1), ", ".join(kinds)]
