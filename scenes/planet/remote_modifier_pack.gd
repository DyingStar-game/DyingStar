@tool
class_name RemoteModifierPack
extends ModifierPack
## The terrain-modifier pack of a planet, streamed tile by tile instead of shipped whole.
##
## tools/planettech/publish/publish_tiles.py splits terrainmodifier.pack into the same tile tree as
## the elevation, under the body [code]<planet>.mod[/code]: one DSTL envelope per (nside, ipix), the
## shard presence maps, the coarse levels in one floor.bin and the pack manifest (string table,
## parts, kind_max_nside). A published tile is the pack tile's exact bytes, so everything after
## [method read_tile] — [method ModifierPack.decode_tile] and every caller of it — is unchanged.
##
## Transport, versions and disk cache are [RemoteTileSource]'s, untouched: this class only maps the
## pack's reads onto it.
##
## WHAT IS BLOCKING, AND WHY
## -------------------------
## [method shared_for] reads the manifest and the floor synchronously, once per planet and
## process (from the disk cache after the first time). The coarsest level carries the WHOLE
## roads and lava flows (PlanetData._whole_lines) that bridges, line profiles and bake keys are
## computed from once and memoised: handing them a half-downloaded level would freeze a wrong
## answer for the session. Every other read never touches the network: [method tile_state]
## queues and answers TILE_PENDING, and the terrain defers the chunk (TileResidency).

## Body suffix of a planet's modifier tiles on the tile service (publish_tiles.MODIFIER_SUFFIX).
const SUFFIX := ".mod"
## How long an unreachable service is left alone before [method shared_for] tries again.
const RETRY_MS := 60000

## Body (planet name + suffix) -> {"pack": RemoteModifierPack or null, "msec": int}. One source per
## body per process: the terrain and the star map read the same tiles through the same cache.
static var _shared: Dictionary = {}
static var _shared_mutex: Mutex = Mutex.new()

## The transport (RemoteTileSource of body <planet>.mod).
var source: RemoteTileSource = null
## Levels the service publishes, as a set: a level not in it holds nothing.
var _served: Dictionary = {}
## Every tile of the floor levels (nside <= source.floor_nside_max), "n/p" -> true. Those levels
## arrive whole in floor.bin, so a tile missing from it is ABSENT — no presence map to ask for.
var _floor: Dictionary = {}
## Floor tiles per level, ascending: [method get_tile_ipix].
var _floor_ipix: Dictionary = {}
var _floor_ready: bool = false


## The streamed pack of [param planet_name], or null when no tile service is configured, it is
## unreachable, or it publishes no modifiers for that planet. Shared and remembered; a failure is
## retried after [constant RETRY_MS]. Blocking on first use (see the class notes).
static func shared_for(planet_name: String) -> RemoteModifierPack:
	return shared_body(planet_name, SUFFIX, "modifiers")


## The same, for any DSMP container streamed under body [param planet_name] + [param suffix]
## whose channel entry says [param dataset] — the regional line bake ([LineBake], ".lines",
## "lines") is one. Null as above, and also when the body is served as another dataset (an older
## whole-file line bake): the caller then takes its own path.
static func shared_body(planet_name: String, suffix: String, dataset: String) -> RemoteModifierPack:
	if planet_name == "" or RemoteTileSource.configured_base_url() == "":
		return null
	var body := planet_name + suffix
	_shared_mutex.lock()
	var known: Dictionary = _shared.get(body, {})
	if not known.is_empty() and (known["pack"] != null
			or Time.get_ticks_msec() - int(known["msec"]) < RETRY_MS):
		_shared_mutex.unlock()
		return known["pack"]
	var pack: RemoteModifierPack = null
	var src := RemoteTileSource.for_planet(body, false)
	if src != null:
		pack = RemoteModifierPack.new()
		if not pack.open_source(src, dataset):
			src.stop()
			pack = null
	_shared[body] = {"pack": pack, "msec": Time.get_ticks_msec()}
	_shared_mutex.unlock()
	return pack


## The streamed pack of [param planet_name] if [method shared_for] has ALREADY opened it, else null —
## never a network call, never a wait: while another thread holds the lock (it is opening a pack, which
## can take an HTTP timeout) the answer is null, and asking again later is the caller's business. For
## what must not stall a frame but should pick the pack up once someone else has opened it (the star
## map's copy of a body that is not loaded, StarMapTiles.offline_data).
static func shared_if_open(planet_name: String) -> RemoteModifierPack:
	if planet_name == "" or not _shared_mutex.try_lock():
		return null
	var known: Dictionary = _shared.get(planet_name + SUFFIX, {})
	_shared_mutex.unlock()
	return known.get("pack") as RemoteModifierPack


## Bind to [param src] (already opened on a [param dataset] body): read the manifest and the
## floor. False when either is unavailable — the planet then runs without modifiers, as with no
## pack.
func open_source(src: RemoteTileSource, dataset: String = "modifiers") -> bool:
	close()
	if src == null or src.dataset != dataset:
		return false
	source = src
	var manifest := _load_manifest()
	if manifest.is_empty():
		push_warning("[RemoteModifierPack] %s: no manifest.json served for version %s"
				% [src.planet, src.version])
		return false
	_apply_manifest(manifest)
	var nsides: Array[int] = []
	for ns: Variant in manifest.get("levels", []):
		nsides.append(int(ns))
	nsides.sort()
	_levels_sorted = PackedInt64Array(nsides)
	for ns: int in nsides:
		_served[ns] = true
	if src.floor_nside_max > 0:
		src.fetch_floor()
		if not FileAccess.file_exists(src.floor_marker_path()):
			push_warning("[RemoteModifierPack] %s: floor.bin unavailable — no modifiers"
					% src.planet)
			return false
		_index_floor()
	_floor_ready = true
	_path = "%s/%s/%s" % [src.base_url, src.planet, src.version]
	print("[RemoteModifierPack] %s version=%s levels %s, floor n..%d: %d tile(s)"
			% [src.planet, src.version, str(_levels_sorted), src.floor_nside_max, _floor.size()])
	return true


func is_streamed() -> bool:
	return true


## The pack manifest of this version: from the disk cache, else from the service (then cached —
## a version's objects never change, see RemoteTileSource).
func _load_manifest() -> Dictionary:
	var path := "%s%s/%s/manifest.json" % [source.cache_root, source.planet, source.version]
	if FileAccess.file_exists(path):
		var cached := StreamChannel.parse_object(FileAccess.get_file_as_string(path))
		if not cached.is_empty():
			return cached
	var res: Array = source._request("%s/%s/%s/manifest.json"
			% [source.base_url, source.planet, source.version])
	if int(res[0]) != 200:
		return {}
	var text := (res[1] as PackedByteArray).get_string_from_utf8()
	var parsed := StreamChannel.parse_object(text)
	if not parsed.is_empty():
		AtomicFile.write_string(path, text)
	return parsed


## List the floor levels' tiles from the disk cache, where fetch_floor() wrote them.
func _index_floor() -> void:
	_floor.clear()
	_floor_ipix.clear()
	var root := "%s%s/%s/" % [source.cache_root, source.planet, source.version]
	for ns: int in _served:
		if ns > source.floor_nside_max:
			continue
		var found: Array[int] = []
		var level := DirAccess.open("%sn%d" % [root, ns])
		if level == null:
			_floor_ipix[ns] = PackedInt64Array()
			continue
		for shard: String in level.get_directories():
			var d := DirAccess.open("%sn%d/%s" % [root, ns, shard])
			if d == null:
				continue
			for f: String in d.get_files():
				if f.begins_with("f") and f.ends_with(".bin"):
					var ipix := int(f.substr(1, f.length() - 5))
					found.append(ipix)
					_floor["%d/%d" % [ns, ipix]] = true
		found.sort()
		_floor_ipix[ns] = PackedInt64Array(found)


func _is_floor_level(nside: int) -> bool:
	return _floor_ready and source != null and nside <= source.floor_nside_max


func tile_state(nside: int, ipix: int) -> int:
	if source == null or not _served.has(nside):
		return TILE_ABSENT
	if _is_floor_level(nside):
		return TILE_READY if _floor.has("%d/%d" % [nside, ipix]) else TILE_ABSENT
	match source.presence_of(nside, ipix):
		RemoteTileSource.PRESENCE_NO:
			return TILE_ABSENT
		RemoteTileSource.PRESENCE_UNKNOWN:
			return TILE_PENDING
	if FileAccess.file_exists(source.tile_cache_path(nside, ipix)):
		return TILE_READY
	source.queue(nside, ipix)
	return TILE_PENDING


## Put tile ([param nside], [param ipix]) on the download queue if it is published and not here
## yet. Never blocks; for the look-ahead (TileResidency.prefetch).
func prefetch_tile(nside: int, ipix: int) -> void:
	if source == null or not _served.has(nside) or _is_floor_level(nside):
		return
	if source.presence_of(nside, ipix) == RemoteTileSource.PRESENCE_YES:
		source.queue(nside, ipix)


func has_tile(nside: int, ipix: int) -> bool:
	return tile_state(nside, ipix) == TILE_READY


## The tile's bytes from the disk cache, or empty: absent, or not downloaded yet (then queued).
## A known-absent tile costs no file access — the mountain relief asks on every height sample.
func read_tile(nside: int, ipix: int) -> PackedByteArray:
	if source == null or not _served.has(nside):
		return PackedByteArray()
	if _is_floor_level(nside):
		if not _floor.has("%d/%d" % [nside, ipix]):
			return PackedByteArray()
		return source.take(nside, ipix)
	var presence := source.presence_of(nside, ipix)
	if presence != RemoteTileSource.PRESENCE_YES:
		return PackedByteArray()
	var raw := source.take(nside, ipix)
	if raw.is_empty():
		source.queue(nside, ipix)
	return raw


## Every tile of a FLOOR level ([param nside] <= the service's floor_nside_max). A finer level is
## never enumerated: that would mean every presence map of the level, i.e. the network.
func get_tile_ipix(nside: int) -> PackedInt64Array:
	if _is_floor_level(nside):
		return _floor_ipix.get(nside, PackedInt64Array())
	push_warning("[RemoteModifierPack] get_tile_ipix(n%d) is only served for the floor levels"
			% nside)
	return PackedInt64Array()


func close() -> void:
	super.close()
	_served.clear()
	_floor.clear()
	_floor_ipix.clear()
	_floor_ready = false
