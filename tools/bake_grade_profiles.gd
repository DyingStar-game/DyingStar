extends Node
## Bake the longitudinal profiles of a planet's profiled lines (railways,
## graded roads, lava flows) into <chunks dir>/grade_profiles.pack, next to
## terrainmodifier.pack.
##
## Why: a profile is a walk over the WHOLE line — the terrain read every 5 m,
## so every elevation tile under it must be there first. A railway round
## tarsis_3 (42 000 km) is 8.5 M reads over ~8 000 tiles: tens of minutes,
## paid by the server AND every client at each start, with the chunks along
## the line rebuilt when it finally lands. The profile only depends on baked
## data, so it is computed once here and read at load in milliseconds
## (PlanetData._ensure_grade_bake). Run it after every export that touches
## the lines or the relief (export_roads.py, export_mountains.py,
## export_volcanoes.py, export_biomes.py, a new elevation version):
## test_grade_profiles_bake_fresh fails until then, and the game falls back to
## profiling at run time.
##
## Run with (the elevation comes from the tile service in client.ini):
##   godot --headless --path . res://tools/bake_grade_profiles.tscn -- --planet=tarsis_3
## Several planets: --planet=tarsis_3,tarsis_8. Without --planet, every
## planet scene whose modifier pack carries a profiled line.
## --fetchers=N sets the parallel tile downloads (default 8).

const SCENES_DIR := "res://scenes/systems"

var _fetchers := 8
## stdout is buffered through the observability bridge: progress goes to
## user://grade_bake.log too, flushed line by line.
var _log: FileAccess = null


func _say(t: String) -> void:
	if _log == null:
		_log = FileAccess.open("user://grade_bake.log", FileAccess.WRITE)
	_log.store_line(t)
	_log.flush()
	print(t)


func _err(t: String) -> void:
	_say("ERROR " + t)
	printerr(t)


func _ready() -> void:
	var planets := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--planet="):
			for p in a.trim_prefix("--planet=").split(",", false):
				planets.append(p.strip_edges())
		elif a.begins_with("--fetchers="):
			_fetchers = maxi(int(a.trim_prefix("--fetchers=")), 1)
	if planets.is_empty():
		planets = _all_planets()
	var failed := 0
	for p in planets:
		if not _bake(p):
			failed += 1
	_say("[GradeBake] done — %d planet(s), %d failed" % [planets.size(), failed])
	get_tree().quit(1 if failed else 0)


## Planet scenes under SCENES_DIR (recursively), by planet name.
func _planet_scenes() -> Dictionary:
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


func _all_planets() -> PackedStringArray:
	var out := PackedStringArray()
	for name: String in _planet_scenes():
		var data := _planet_data(name)
		if data != null and data.chunk_heightmaps_dir != "":
			data.apply_chunk_manifest()
			if data.has_profiled_lines():
				out.append(name)
	return out


## The planet's own PlanetData, as its scene configures it — read from the
## PackedScene state, nothing instantiated.
func _planet_data(planet: String) -> PlanetData:
	var path: String = _planet_scenes().get(planet, "")
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


## The crack exclusion spheres PlanetTerrain hands the sampler, read from the
## planet's scene file (PlanetTerrain.crack_exclusion_pois_of_scene).
func _scene_crack_pois(planet: String) -> Array:
	var path: String = _planet_scenes().get(planet, "")
	return PlanetTerrain.crack_exclusion_pois_of_scene(load(path) as PackedScene if path != "" else null)


func _bake(planet: String) -> bool:
	var t_start := Time.get_ticks_msec()
	_say("[GradeBake] === %s ===" % planet)
	var data := _planet_data(planet)
	if data == null:
		_err("[GradeBake] %s: no planet scene with a PlanetData under %s" % [planet, SCENES_DIR])
		return false
	# The same preparation as PlanetTerrain.initialize, in the same order.
	data.apply_chunk_manifest()
	data.remote_source = RemoteTileSource.for_planet(planet)
	if data.remote_source == null:
		_err("[GradeBake] %s: no tile service — the elevation is not in the repository, "
				% planet + "configure the service in client.ini")
		return false
	# Compute, never read back an older bake while doing so.
	data._grade_bake_tried = true
	data._bridge_bake_checked = true
	# The crack network spares the POI spheres: set them as PlanetTerrain
	# does, BEFORE the crossings are walked (bridge_bake_key holds them).
	data.set_crack_exclusions(_scene_crack_pois(planet))
	data.ensure_queries_loaded()
	data.warm_mountains()
	data.warm_fumaroles()
	data.has_lava()
	# The lazy gates the sampler reads, resolved here and not raced by the
	# station workers below.
	data.has_profiled_lines()
	data.has_relief_biomes()

	var lines := data._whole_profiled_lines()
	if lines.is_empty() and not (data.corundum_default_biome and data.has_roads()):
		_say("[GradeBake] %s: no profiled line and no chasm crossing — nothing to bake" % planet)
		return true

	# 1. The tiles under every line, fetched in parallel.
	var t0 := Time.get_ticks_msec()
	var tiles_by_fid := {}
	var wanted := {}
	for road in lines:
		var tiles := data._grade_tiles(road)
		tiles_by_fid[int(road.get("feature_id", -1))] = tiles
		wanted.merge(tiles)
	_say("[GradeBake] %s: %d line(s), %d export tile(s) under them (walk %d ms)"
			% [planet, lines.size(), wanted.size(), Time.get_ticks_msec() - t0])
	t0 = Time.get_ticks_msec()
	var got := _fetch_parallel(data, wanted.keys())
	_say("[GradeBake] %s: %d/%d tile(s) present after download (%d s)"
			% [planet, got, wanted.size(), (Time.get_ticks_msec() - t0) / 1000])
	t0 = Time.get_ticks_msec()
	var anc := _fetch_ancestors(data, wanted.keys())
	_say("[GradeBake] %s: %d published ancestor(s) of pruned tiles fetched (%d s)"
			% [planet, anc, (Time.get_ticks_msec() - t0) / 1000])

	# 2. Profile every line whose tiles are all readable.
	var profiles := {}
	var baked_lines: Array = []
	for road in lines:
		var fid := int(road.get("feature_id", -1))
		if not _wait_tiles(data, tiles_by_fid[fid], fid):
			continue
		var tc := Time.get_ticks_msec()
		var prof := _compute_parallel(data, road)
		if not bool(prof.get("ok", false)):
			_err("[GradeBake] %s fid %d: GradeProfile refused the line" % [planet, fid])
			continue
		profiles[fid] = prof
		baked_lines.append(road)
		_say("[GradeBake] %s fid %d (%s): %.0f km, %d knot(s), %d segment(s) — %d s"
				% [planet, fid, str(road.get("road_type", "")),
				(float(prof["along1"]) - float(prof["along0"])) / 1000.0,
				(prof["knots_along"] as PackedFloat64Array).size(),
				(prof["segments"] as Array).size(), (Time.get_ticks_msec() - tc) / 1000])

	# 3. The chasm crossings and their deck plans.
	var bridges := {}
	var bridges_ok := true
	if data.corundum_default_biome and data.has_roads():
		var tb := Time.get_ticks_msec()
		var spans := data.get_bridge_spans()
		_say("[GradeBake] %s: %d chasm crossing(s) found in %d s"
				% [planet, spans.size(), (Time.get_ticks_msec() - tb) / 1000])
		tb = Time.get_ticks_msec()
		var span_tiles := {}
		for sp in spans:
			if not sp.get("truncated", false):
				span_tiles[HEALPix.vec2pix_nest(data.export_nside, sp["mid_dir"])] = true
		_fetch_parallel(data, span_tiles.keys())
		# A pruned span tile is planned on its finest published ancestor
		# (TileResidency.tile_available): read the presence maps down the
		# chain on the planet's own source and fetch those ancestors.
		_fetch_ancestors(data, span_tiles.keys())
		data._ensure_bridge_plans()
		if data.bridge_plans_incomplete():
			_err("[GradeBake] %s: %d span(s) still wait for their tile — crossings not baked"
					% [planet, data._bridge_spans_starved.size()])
			bridges_ok = false
		else:
			bridges = {"spans": spans, "plans": data._bridge_plans}
			_say("[GradeBake] %s: %d deck plan(s) over %d span tile(s) in %d s"
					% [planet, data._bridge_plans.size(), span_tiles.size(),
					(Time.get_ticks_msec() - tb) / 1000])

	# 4. Write, and read back through the game's own loader.
	var err := data.write_grade_bake(baked_lines, profiles, bridges)
	if err != OK:
		_err("[GradeBake] %s: cannot write %s (%s)" % [planet, data.grade_bake_path(), error_string(err)])
		return false
	var size := FileAccess.get_file_as_bytes(data.grade_bake_path()).size()
	data._grade_bake_doc_read = false
	data._grade_bake_doc = {}
	data._grade_bake_tried = false
	data._grade_baked.clear()
	data._bridge_bake_checked = false
	data._bridge_baked = {}
	var readable := 0
	for road in baked_lines:
		if not data._grade_baked_profile(road).is_empty():
			readable += 1
	var bridges_read := not data._baked_bridges().is_empty()
	_say("[GradeBake] %s: %s — %d/%d line(s) baked, crossings %s, %.1f MB, %d s in all"
			% [planet, data.grade_bake_path(), readable, lines.size(),
			"baked" if bridges_read else "NOT baked",
			float(size) / 1048576.0, (Time.get_ticks_msec() - t_start) / 1000])
	if data.remote_source != null:
		data.remote_source.stop()
	return readable == baked_lines.size() and baked_lines.size() == lines.size() \
			and bridges_ok and (bridges.is_empty() or bridges_read)


## Download [param tiles] (export level) with _fetchers connections of their
## own: RemoteTileSource.fetch_now shares one connection per source, so one
## source per fetcher. Returns how many are on disk afterwards.
func _fetch_parallel(data: PlanetData, tiles: Array) -> int:
	var base := RemoteTileSource.configured_base_url()
	var srcs: Array = []
	for k in _fetchers:
		var s := RemoteTileSource.new()
		if s.open_planet(base, data.planet_name):
			srcs.append(s)
	if srcs.is_empty():
		srcs.append(data.remote_source)
	var ns := data.export_nside
	var n_src := srcs.size()
	var task := WorkerThreadPool.add_group_task(func(k: int) -> void:
		var src: RemoteTileSource = srcs[k]
		var i := k
		while i < tiles.size():
			src.fetch_now(ns, int(tiles[i]))
			i += n_src,
		n_src, n_src, true, "grade bake tile fetch")
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
func _fetch_ancestors(data: PlanetData, tiles: Array) -> int:
	var src := data.remote_source
	var ancestors := {}
	for t in tiles:
		var ns := data.export_nside
		var ip := int(t)
		while ns >= data.export_nside_min:
			if src.has_tile(ns, ip):
				if ns != data.export_nside:
					ancestors[Vector2i(ns, ip)] = true
				break
			ns >>= 1
			ip >>= 2
	var keys: Array = ancestors.keys()
	if keys.is_empty():
		return 0
	var base := RemoteTileSource.configured_base_url()
	var srcs: Array = []
	for k in _fetchers:
		var s := RemoteTileSource.new()
		if s.open_planet(base, data.planet_name):
			srcs.append(s)
	if srcs.is_empty():
		srcs.append(src)
	var n_src := srcs.size()
	var task := WorkerThreadPool.add_group_task(func(k: int) -> void:
		var f: RemoteTileSource = srcs[k]
		var i := k
		while i < keys.size():
			var a: Vector2i = keys[i]
			f.fetch_now(a.x, a.y)
			i += n_src,
		n_src, n_src, true, "grade bake ancestor fetch")
	WorkerThreadPool.wait_for_group_task_completion(task)
	return keys.size()


## Wait until every tile under a line is readable — pruned tiles climb to
## their finest published ancestor, which the source fetches on its own
## thread once _grade_tiles_missing has queued it. False when one never can.
func _wait_tiles(data: PlanetData, tiles: Dictionary, fid: int) -> bool:
	var deadline := Time.get_ticks_msec() + 60000
	var next_report := 0
	while true:
		var state := data._grade_tiles_missing(tiles)
		var missing := int(state["missing"])
		if missing == 0:
			return true
		if Time.get_ticks_msec() >= next_report:
			next_report = Time.get_ticks_msec() + 10000
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
				_say("[GradeBake]   first missing tile chain:%s" % chain)
				break
			_say("[GradeBake] %s fid %d: waiting for %d tile(s) — states %s — source queue %d, fetched %d, failed %d"
					% [data.planet_name, fid, missing, str(hist), src._queue.size(),
					src.stat_fetched, src.stat_failed])
		if bool(state["hopeless"]):
			_err("[GradeBake] %s fid %d: %d tile(s) can never be read — line not baked"
					% [data.planet_name, fid, missing])
			return false
		if Time.get_ticks_msec() > deadline:
			_err("[GradeBake] %s fid %d: %d tile(s) still missing after 60 s — line not baked"
					% [data.planet_name, fid, missing])
			return false
		OS.delay_msec(500)
	return false


## GradeProfile.compute with the stations — the bulk of the work, and
## independent of one another — read on every core, one sampler per slice.
## The knots (a sequential walk, 40× fewer reads) stay on this thread.
func _compute_parallel(data: PlanetData, road: Dictionary) -> Dictionary:
	var cum: PackedFloat64Array = road.get("_cum_lengths", PackedFloat64Array())
	if cum.size() < 2:
		return {"ok": false}
	var alongs := GradeProfile.station_alongs(cum[0], cum[cum.size() - 1])
	var n := alongs.size()
	# Many small slices: the progress below is counted in slices, and a slow
	# stretch (a mountain range) does not pin one worker for the whole run.
	var n_parts := clampi(n / 2000, 1, 20000)
	var per := ceili(float(n) / float(n_parts))
	var parts: Array = []
	for i in n_parts:
		parts.append([PackedFloat64Array(), 0])
	var t0 := Time.get_ticks_msec()
	var task := WorkerThreadPool.add_group_task(func(i: int) -> void:
		var i0 := i * per
		var i1 := mini(i0 + per, n)
		if i0 < i1:
			var tu := Time.get_ticks_usec()
			var slot: Array = parts[i]
			slot[0] = GradeProfile.sample_stations(road, data.grade_height_sampler(), alongs, i0, i1)
			slot[1] = Time.get_ticks_usec() - tu,
		n_parts, -1, true, "grade bake stations")
	var fid := int(road.get("feature_id", -1))
	var next_report := t0 + 10000
	while not WorkerThreadPool.is_group_task_completed(task):
		OS.delay_msec(100)
		if Time.get_ticks_msec() < next_report:
			continue
		next_report += 10000
		var done := WorkerThreadPool.get_group_processed_element_count(task)
		var el := float(Time.get_ticks_msec() - t0) / 1000.0
		_say("[GradeBake]   fid %d stations: %d/%d slice(s) — %.0f s, ~%.0f s left"
				% [fid, done, n_parts, el, el * float(n_parts - done) / maxf(float(done), 1.0)])
	WorkerThreadPool.wait_for_group_task_completion(task)
	var st := PackedFloat64Array()
	var slow: Array = []
	for i in n_parts:
		var slot: Array = parts[i]
		st.append_array(slot[0])
		slow.append([int(slot[1]), i])
	slow.sort_custom(func(a, b): return a[0] > b[0])
	var worst := ""
	for k in mini(5, slow.size()):
		var i: int = slow[k][1]
		var mid := alongs[mini(i * per + per / 2, n - 1)]
		var ll := GradeGeom.lonlat_at(road["centerline"], cum, mid)
		worst += " %.0f us/st @ %.0f km (%.2f, %.2f);" % [float(slow[k][0]) / per, mid / 1000.0, ll.x, ll.y]
	_say("[GradeBake]   fid %d stations read in %d s — slowest slices:%s"
			% [fid, (Time.get_ticks_msec() - t0) / 1000, worst])
	var tk := Time.get_ticks_msec()
	var prof := GradeProfile.compute(road, data.grade_height_sampler(), null, st)
	_say("[GradeBake]   fid %d knots + segments in %d s" % [fid, (Time.get_ticks_msec() - tk) / 1000])
	return prof
