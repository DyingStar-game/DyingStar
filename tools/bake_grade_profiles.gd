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
## --tile-channel=CHANNEL reads that channel (StreamChannel) — unstable right after an export.
## --log=PATH writes the progress there instead of user://grade_bake.log (the QGIS plugin's
## « Recuire les profils des lignes » follows it).
## --no-publish leaves the bake local: the caller publishes it (the QGIS plugin, from its own
## export folder).

const HeadlessPlanet := preload("res://tools/planettech/headless_planet.gd")
const SCENES_DIR := HeadlessPlanet.SCENES_DIR

var _fetchers := 8
## stdout is buffered through the observability bridge: progress goes to
## user://grade_bake.log too, flushed line by line.
var _log: FileAccess = null
var _log_path := "user://grade_bake.log"
var _publish_bake := true


func _say(t: String) -> void:
	if _log == null:
		_log = FileAccess.open(_log_path, FileAccess.WRITE)
	if _log != null:
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
		elif a.begins_with("--log="):
			_log_path = a.trim_prefix("--log=")
		elif a == "--no-publish":
			_publish_bake = false
	if planets.is_empty():
		planets = _all_planets()
	var failed := 0
	for p in planets:
		if not _bake(p):
			failed += 1
	_say("[GradeBake] done — %d planet(s), %d failed" % [planets.size(), failed])
	get_tree().quit(1 if failed else 0)


func _planet_scenes() -> Dictionary:
	return HeadlessPlanet.planet_scenes()


func _all_planets() -> PackedStringArray:
	var out := PackedStringArray()
	for name: String in _planet_scenes():
		var data := _planet_data(name)
		if data != null and data.chunk_heightmaps_dir != "":
			data.apply_chunk_manifest()
			data.connect_tile_service()  # the lines are in the streamed modifiers
			if data.has_profiled_lines():
				out.append(name)
	return out


## The planet's own PlanetData, as its scene configures it (headless_planet.gd).
func _planet_data(planet: String) -> PlanetData:
	return HeadlessPlanet.planet_data(planet)


## The crack exclusion spheres PlanetTerrain hands the sampler, read from the
## planet's <planet>_poi.json (PlanetTerrain.poi_crack_exclusions).
func _scene_crack_pois(planet: String) -> Array:
	return PlanetTerrain.poi_crack_exclusions(planet)


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
	data.attach_remote_modifiers()
	if data.remote_source == null:
		_err("[GradeBake] %s: no tile service — the elevation is not in the repository, "
				% planet + "configure the service in client.ini")
		return false
	if data.remote_modifiers == null:
		_err("[GradeBake] %s: the tile service serves no modifiers (body %s%s) on channel %s — "
				% [planet, planet, RemoteModifierPack.SUFFIX, StreamChannel.configured_name()]
				+ "publish the linked terrainmodifier.pack first (publish_tiles.py), then bake "
				+ "with --tile-channel=unstable")
		return false
	# Compute, never read back an older bake while doing so.
	data._grade_bake_tried = true
	data._bridge_bake_checked = true
	# The crack network spares the POI spheres: set them as PlanetTerrain
	# does, BEFORE the crossings are walked (bridge_bake_key holds them).
	data.set_crack_exclusions(_scene_crack_pois(planet))
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
	# Read back THIS file, not the published bake the game would fetch.
	data.grade_bake_local_path = data.grade_bake_path()
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
	var complete := readable == baked_lines.size() and baked_lines.size() == lines.size() \
			and bridges_ok and (bridges.is_empty() or bridges_read)
	# Only a complete bake goes out; an incomplete one (lines or crossings missing) stays local.
	if complete and _publish_bake:
		_publish(data.grade_bake_path())
	return complete


## Hand the fresh bake to the tile service (tools/planettech/publish/publish_remote.py, in the
## background): the game reads only the published bake (body <planet>.lines). Without a target
## configured the script says so and nothing is sent.
func _publish(bake_path: String) -> void:
	var script := ProjectSettings.globalize_path("res://tools/planettech/publish/publish_remote.py")
	var out: Array = []
	OS.execute("python3", [script, ProjectSettings.globalize_path(bake_path), "--background"], out, true)
	for line: Variant in out:
		_say("[GradeBake] %s" % str(line).strip_edges())


## Download [param tiles] (export level) in parallel (tools/planettech/headless_planet.gd).
## Returns how many are on disk afterwards.
func _fetch_parallel(data: PlanetData, tiles: Array) -> int:
	return HeadlessPlanet.fetch_parallel(data, tiles, _fetchers)


## The published ancestors of the pruned tiles (tools/planettech/headless_planet.gd).
## Returns how many were fetched.
func _fetch_ancestors(data: PlanetData, tiles: Array) -> int:
	return HeadlessPlanet.fetch_ancestors(data, tiles, _fetchers)


## Wait until every tile under a line is readable (tools/planettech/headless_planet.gd).
## False when one never can: the line is then not baked.
func _wait_tiles(data: PlanetData, tiles: Dictionary, fid: int) -> bool:
	return HeadlessPlanet.wait_tiles(data, tiles, "[GradeBake] %s fid %d" % [data.planet_name, fid],
			_say, func(t: String) -> void: _err(t + " — line not baked"))


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
