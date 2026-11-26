extends RefCounted
## A planet for a headless tool: its scene's PlanetData, and the elevation tiles it reads,
## fetched before it samples — in parallel, the published ancestors of the pruned ones, then a
## wait until every one is readable. Shared by tools/bake_grade_profiles.gd and
## tools/planettech/terrain_dem.gd. Static only:
##   const HeadlessPlanet := preload("res://tools/planettech/headless_planet.gd")

const SCENES_DIR := "res://scenes/systems"


## Planet scenes under SCENES_DIR (recursively), by planet name.
static func planet_scenes() -> Dictionary:
	var out := {}
	var dirs: Array[String] = [SCENES_DIR]
	while not dirs.is_empty():
		var d: String = dirs.pop_back()
		for sub in DirAccess.get_directories_at(d):
			dirs.append(d.path_join(sub))
		for f in DirAccess.get_files_at(d):
			if f.ends_with(".tscn"):
				out[f.get_basename()] = d.path_join(f)
	return out


## The planet's own PlanetData, as its scene configures it — read from the
## PackedScene state, nothing instantiated. null when no scene has one.
static func planet_data(planet: String) -> PlanetData:
	var path: String = planet_scenes().get(planet, "")
	if path == "":
		return null
	var ps := load(path) as PackedScene
	if ps == null:
		return null
	var st := ps.get_state()
	for ni in st.get_node_count():
		for pi in st.get_node_property_count(ni):
			if st.get_node_property_name(ni, pi) == &"planet_data":
				var res: Variant = st.get_node_property_value(ni, pi)
				if res is PlanetData:
					return (res as PlanetData).duplicate(true)
	return null


## Download [param tiles] (level [param nside], the export level by default) with
## [param fetchers] connections of their own: RemoteTileSource.fetch_now shares one connection
## per source, so one source per fetcher. Returns how many are on disk afterwards.
static func fetch_parallel(data: PlanetData, tiles: Array, fetchers: int, nside: int = -1) -> int:
	var srcs := _sources(data, fetchers)
	var ns := nside if nside > 0 else data.export_nside
	var n_src := srcs.size()
	var task := WorkerThreadPool.add_group_task(func(k: int) -> void:
		var src: RemoteTileSource = srcs[k]
		var i := k
		while i < tiles.size():
			src.fetch_now(ns, int(tiles[i]))
			i += n_src,
		n_src, n_src, true, "tool tile fetch")
	WorkerThreadPool.wait_for_group_task_completion(task)
	var present := 0
	for t in tiles:
		if FileAccess.file_exists(data.remote_source.tile_cache_path(ns, int(t))):
			present += 1
	return present


## A tile the service pruned is read on its finest PUBLISHED ancestor
## (TileResidency.tile_available). The game learns the presence maps and
## fetches those ancestors on the source's own thread; a tool may block:
## the maps are read here, on the planet's source (so its presence_of()
## knows them afterwards), and the ancestors fetched in parallel.
## Returns how many ancestors were fetched.
static func fetch_ancestors(data: PlanetData, tiles: Array, fetchers: int,
		nside: int = -1) -> int:
	var src := data.remote_source
	var level := nside if nside > 0 else data.export_nside
	var ancestors := {}
	for t in tiles:
		var ns := level
		var ip := int(t)
		while ns >= data.export_nside_min:
			if src.has_tile(ns, ip):
				if ns != level:
					ancestors[Vector2i(ns, ip)] = true
				break
			ns >>= 1
			ip >>= 2
	var keys: Array = ancestors.keys()
	if keys.is_empty():
		return 0
	var srcs := _sources(data, fetchers)
	var n_src := srcs.size()
	var task := WorkerThreadPool.add_group_task(func(k: int) -> void:
		var f: RemoteTileSource = srcs[k]
		var i := k
		while i < keys.size():
			var a: Vector2i = keys[i]
			f.fetch_now(a.x, a.y)
			i += n_src,
		n_src, n_src, true, "tool ancestor fetch")
	WorkerThreadPool.wait_for_group_task_completion(task)
	return keys.size()


## Wait until every tile of [param tiles] (export ipix -> true) is readable — pruned tiles
## climb to their finest published ancestor, which the source fetches on its own thread once
## PlanetData._grade_tiles_missing has queued it. False when one never can, or after
## [param timeout_ms]. [param what] names the job in the messages; [param say] and
## [param err] print a line.
static func wait_tiles(data: PlanetData, tiles: Dictionary, what: String, say: Callable,
		err: Callable, timeout_ms: int = 60000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	var next_report := 0
	while true:
		var state := data._grade_tiles_missing(tiles)
		var missing := int(state["missing"])
		if missing == 0:
			return true
		if Time.get_ticks_msec() >= next_report:
			next_report = Time.get_ticks_msec() + 10000
			_report(data, tiles, what, missing, say)
		if bool(state["hopeless"]):
			err.call("%s: %d tile(s) can never be read" % [what, missing])
			return false
		if Time.get_ticks_msec() > deadline:
			err.call("%s: %d tile(s) still missing after %d s" % [what, missing, timeout_ms / 1000])
			return false
		OS.delay_msec(500)
	return false


static func _report(data: PlanetData, tiles: Dictionary, what: String, missing: int,
		say: Callable) -> void:
	var hist := {}
	for ipix: int in tiles:
		if data._grade_tile_available(ipix):
			continue
		var st := TileResidency.finest_published_ancestor_state(data, ipix, data.export_nside)
		hist[st] = int(hist.get(st, 0)) + 1
	var src := data.remote_source
	for ipix: int in tiles:
		if data._grade_tile_available(ipix):
			continue
		var chain := ""
		var ns := data.export_nside
		var ip := ipix
		while ns >= data.export_nside_min:
			chain += " n%d/%d:p%d,f%d" % [ns, ip, src.presence_of(ns, ip),
					int(not data.load_chunk_floats(ip, ns).is_empty())]
			ns >>= 1
			ip >>= 2
		say.call("  first missing tile chain:%s" % chain)
		break
	say.call("%s: waiting for %d tile(s) — states %s — source queue %d, fetched %d, failed %d"
			% [what, missing, str(hist), int(src.queue_stats()["queued"]),
			src.stat_fetched, src.stat_failed])


## [param fetchers] sources of their own on the configured service, or the planet's.
static func _sources(data: PlanetData, fetchers: int) -> Array:
	var base := RemoteTileSource.configured_base_url()
	var srcs: Array = []
	for k in fetchers:
		var s := RemoteTileSource.new()
		if s.open_planet(base, data.planet_name):
			srcs.append(s)
	if srcs.is_empty():
		srcs.append(data.remote_source)
	return srcs
