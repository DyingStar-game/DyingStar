extends Node
## The ground a road is built on, over an area, for QGIS: a grid of altitudes sampled through
## PlanetData.grade_height_sampler — the very function the road and railway profiles read
## (heightmap + mountain ranges + ridges + volcanoes + rocky terrain; no cracks, no biome
## relief), so a slope seen in QGIS is the slope the game lays the road on.
##
## Run by the DyingStar QGIS plugin (Routes ▸ Terrain de la zone, source "Exact"), or by hand:
##   godot --headless --path . res://tools/planettech/terrain_dem.tscn -- --planet=tarsis_3 \
##       --bbox=-40.2,24.5,-39.8,24.9 --pitch=25 --out=/tmp/dem
## Arguments (after --):
##   --planet=NAME            the planet scene under res://scenes/systems
##   --grid=LON0,DLON,NX,LAT_TOP,DLAT,NY
##                            the sample nodes: lon = LON0 + i·DLON, lat = LAT_TOP − j·DLAT
##                            (the plugin's grid, the same as its quick source)
##   --bbox=LON0,LAT0,LON1,LAT1 --pitch=M
##                            or a box and a pitch in metres (default: the finest terrain
##                            vertex pitch, where the mountains keep every octave)
##   --out=PATH               writes PATH.f32 (float32 little-endian, NY rows of NX, row 0 =
##                            north), PATH.json (the grid, the radius, what was read) and,
##                            with --cracks, PATH.cracks.f32 (corundum chasm depth, m, ≥ 0)
##   --local-modifiers=PACK   read this terrainmodifier.pack instead of the published one: a
##                            massif just exported (link_modifiers.link) shows without publishing
##   --tile-channel=CHANNEL   the elevation channel (unstable, dev…), as the game takes it
##   --fetchers=N             parallel tile downloads (8)   --verify=N  self-check samples (256)
## Progress lines go to PATH.log, flushed (stdout is buffered through the observability bridge).
## Exit code: 0 written (see "complete" in the json), 1 refused.

const HeadlessPlanet := preload("res://tools/planettech/headless_planet.gd")
## Past this the grid is refused: 64 M samples is 256 MB of floats and minutes of sampling.
const MAX_SAMPLES := 64_000_000
## Past this many tiles to download the request is refused (raise the pitch or zoom in): the
## pitch picks the pyramid level, so only a large area at a fine pitch gets here.
const MAX_TILES := 20_000
## Tile frames a worker keeps: a row crosses a few dozen tiles at most.
const FRAMES_KEPT := 64

var _log: FileAccess = null
var _fetchers := 8
var _verify := 256


func _say(t: String) -> void:
	if _log != null:
		_log.store_line(t)
		_log.flush()
	print(t)


func _err(t: String) -> void:
	_say("ERROR " + t)
	printerr(t)


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and "=" in a:
			args[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)
		elif a.begins_with("--"):
			args[a.substr(2)] = "true"
	var out := str(args.get("out", ""))
	if out != "":
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		_log = FileAccess.open(out + ".log", FileAccess.WRITE)
	_fetchers = maxi(int(args.get("fetchers", "8")), 1)
	_verify = maxi(int(args.get("verify", "256")), 0)
	var code := _run(args)
	if _log != null:
		_log.close()
	get_tree().quit(code)


func _run(args: Dictionary) -> int:
	var t_start := Time.get_ticks_msec()
	var planet := str(args.get("planet", ""))
	var out := str(args.get("out", ""))
	if planet == "" or out == "":
		_err("[TerrainDem] --planet and --out are required")
		return 1
	var data := HeadlessPlanet.planet_data(planet)
	if data == null:
		_err("[TerrainDem] %s: no planet scene with a PlanetData under %s"
				% [planet, HeadlessPlanet.SCENES_DIR])
		return 1
	# The same preparation as PlanetTerrain.initialize (and the profile bake).
	data.apply_chunk_manifest()
	data.remote_source = RemoteTileSource.for_planet(planet)
	if data.remote_source == null:
		_err("[TerrainDem] %s: no tile service — configure it in client.ini" % planet)
		return 1
	var modifiers := "published"
	var local_pack := str(args.get("local-modifiers", ""))
	if local_pack != "":
		var mp := ModifierPack.new()
		if not mp.open(local_pack):
			_err("[TerrainDem] %s: cannot open the modifier pack %s" % [planet, local_pack])
			return 1
		# What _ensure_modifier_pack does with the streamed pack, with the local one.
		data._modifier_pack = mp
		data._modifier_pack_tried = true
		modifiers = "local " + local_pack
	else:
		data.attach_remote_modifiers()
		if data.remote_modifiers == null:
			_say("[TerrainDem] %s: the service serves no modifiers — heightmap only" % planet)
			modifiers = "none"
	data.set_crack_exclusions(PlanetTerrain.poi_crack_exclusions(planet))
	# The lazy caches the sampler reads, resolved here and not raced by the workers.
	data.warm_mountains()
	data.warm_fumaroles()
	data.has_lava()
	data.has_profiled_lines()
	data.has_relief_biomes()

	var grid := _grid(args, data)
	if grid.is_empty():
		return 1
	var nx: int = grid["nx"]
	var ny: int = grid["ny"]
	var level := _level_for(data, float(grid["pitch_m"]))
	var ns: int = level["nside"]
	var vtx: float = level["vtx_spacing_m"]
	_say("[TerrainDem] %s: %d × %d nodes (%.1f M), pitch %.1f m, R = %.0f m, modifiers %s — %s"
			% [planet, nx, ny, nx * ny / 1e6, float(grid["pitch_m"]), data.radius,
			modifiers, level["sampler"]])

	# 1. The tiles under the grid (and their neighbours: the bilinear reads across).
	var t0 := Time.get_ticks_msec()
	var tiles := _tiles_under(data, grid, ns)
	_say("[TerrainDem] %d tile(s) n%d under the area" % [tiles.size(), ns])
	if tiles.size() > MAX_TILES:
		_err("[TerrainDem] %d tiles to read is past %d: zoom in or raise the pitch"
				% [tiles.size(), MAX_TILES])
		return 1
	var got := HeadlessPlanet.fetch_parallel(data, tiles.keys(), _fetchers, ns)
	var anc := HeadlessPlanet.fetch_ancestors(data, tiles.keys(), _fetchers, ns)
	_say("[TerrainDem] %d/%d tile(s) downloaded, %d published ancestor(s) — %d s"
			% [got, tiles.size(), anc, (Time.get_ticks_msec() - t0) / 1000])
	var complete := true
	if ns == data.export_nside:
		complete = HeadlessPlanet.wait_tiles(data, tiles, "[TerrainDem] %s" % planet, _say, _err)
		if not complete:
			_say("[TerrainDem] some tiles are missing: those places read the coarse global map")

	# 2. Every node, rows in slices over the cores, one sampler (and tile frame) per slice.
	t0 = Time.get_ticks_msec()
	var cracks := args.has("cracks") and data.corundum_default_biome
	if cracks:
		RoadBridge.chasm_depth_at(data, float(grid["lon0"]), float(grid["lat_top"]))
	# One sampler (and tile frame, whose mountain set is costly to build) per worker, each on
	# every n-th row so the workers end together.
	var n_workers := clampi(OS.get_processor_count(), 1, ny)
	var rows_h: Array = []
	var rows_d: Array = []
	rows_h.resize(ny)
	rows_d.resize(ny)
	var done: Array = []
	done.resize(n_workers)
	done.fill(0)
	var task := WorkerThreadPool.add_group_task(func(k: int) -> void:
		# A tile frame answers in C# only once given its tile's relief (prepare_mountain_frame,
		# as the chunk builders do): one frame per tile, the last few kept (a row crosses them
		# in order, the next row comes back to them).
		var frames := {}
		var j := k
		while j < ny:
			var lat: float = float(grid["lat_top"]) - j * float(grid["dlat"])
			var h := PackedFloat32Array()
			h.resize(nx)
			var d := PackedFloat32Array()
			if cracks:
				d.resize(nx)
			for i in nx:
				var lon: float = float(grid["lon0"]) + i * float(grid["dlon"])
				var dir := RoadBridge.lonlat_to_dir(lon, lat)
				var ipix := HEALPix.vec2pix_nest(ns, dir)
				var frame: Variant = frames.get(ipix)
				if frame == null:
					if frames.size() >= FRAMES_KEPT:
						frames.clear()
					frame = data.make_tile_frame()
					data.prepare_mountain_frame(frame, ns, ipix)
					frames[ipix] = frame
				h[i] = data.sample_height_for_direction(dir, -1, -1, Vector2i(-1, -1), null, ns,
						frame, vtx, CrackCarve.NONE)
				if cracks:
					d[i] = RoadBridge.chasm_depth_at(data, lon, lat)
			rows_h[j] = h
			rows_d[j] = d
			done[k] = int(done[k]) + 1
			j += n_workers,
		n_workers, n_workers, true, "terrain dem")
	var next_report := Time.get_ticks_msec() + 1000
	while not WorkerThreadPool.is_group_task_completed(task):
		OS.delay_msec(100)
		if Time.get_ticks_msec() >= next_report:
			next_report += 1000
			var n_done := 0
			for c: int in done:
				n_done += c
			_say("[TerrainDem] progress %.3f" % (float(n_done) / ny))
	WorkerThreadPool.wait_for_group_task_completion(task)
	var grid_h := PackedFloat32Array()
	var grid_d := PackedFloat32Array()
	for j in ny:
		grid_h.append_array(rows_h[j])
		if cracks:
			grid_d.append_array(rows_d[j])
	var sample_s := float(Time.get_ticks_msec() - t0) / 1000.0
	_say("[TerrainDem] sampled in %.1f s (%.2f µs/node)" % [sample_s, sample_s * 1e6 / (nx * ny)])

	# 3. Self-check: random nodes again, on this thread with a fresh sampler — must be equal.
	var worst := _verify_nodes(grid, grid_h, _sampler(data, ns, vtx))
	_say("[TerrainDem] self-check: %d node(s), max |Δ| = %.6f m" % [_verify, worst])

	# 4. Write.
	if not _write(out + ".f32", grid_h) or (cracks and not _write(out + ".cracks.f32", grid_d)):
		return 1
	var lo := INF
	var hi := -INF
	for v in grid_h:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var meta := grid.duplicate()
	meta.merge({
		"planet": planet,
		"radius_m": data.radius,
		"export_nside": data.export_nside,
		"nside": ns,
		"vtx_spacing_m": vtx,
		"sampler": level["sampler"],
		"exact": level["exact"],
		"modifiers": modifiers,
		"tile_channel": StreamChannel.configured_name(),
		"complete": complete,
		"cracks": cracks,
		"min_m": lo,
		"max_m": hi,
		"verify_nodes": _verify,
		"verify_max_abs_diff_m": worst,
		"seconds": float(Time.get_ticks_msec() - t_start) / 1000.0,
	})
	var fh := FileAccess.open(out + ".json", FileAccess.WRITE)
	if fh == null:
		_err("[TerrainDem] cannot write %s.json" % out)
		return 1
	fh.store_string(JSON.stringify(meta, " ", true))
	fh.close()
	if data.remote_source != null:
		data.remote_source.stop()
	_say("[TerrainDem] done: %s.f32 — %.0f … %.0f m, %d s in all"
			% [out, lo, hi, (Time.get_ticks_msec() - t_start) / 1000])
	return 0


## The sample nodes: --grid as given, or --bbox at --pitch (east-west pitch at the box's mid
## latitude, nodes on the box's west and north edges — export/planet/mountain_preview.py
## grid_for_box). Empty (and said why) when refused.
func _grid(args: Dictionary, data: PlanetData) -> Dictionary:
	var g := {}
	if args.has("grid"):
		var p := str(args["grid"]).split(",")
		if p.size() != 6:
			_err("[TerrainDem] --grid takes LON0,DLON,NX,LAT_TOP,DLAT,NY")
			return {}
		g = {"lon0": float(p[0]), "dlon": float(p[1]), "nx": int(p[2]),
			"lat_top": float(p[3]), "dlat": float(p[4]), "ny": int(p[5])}
	elif args.has("bbox"):
		var b := str(args["bbox"]).split(",")
		if b.size() != 4:
			_err("[TerrainDem] --bbox takes LON0,LAT0,LON1,LAT1")
			return {}
		var pitch := float(args.get("pitch", str(data.terrain_vertex_spacing_m())))
		var m_per_deg := data.radius * PI / 180.0
		var clat := maxf(cos(deg_to_rad((float(b[1]) + float(b[3])) * 0.5)), 0.05)
		var dlat := pitch / m_per_deg
		var dlon := dlat / clat
		g = {"lon0": float(b[0]), "dlon": dlon,
			"nx": int(ceil((float(b[2]) - float(b[0])) / dlon)) + 1,
			"lat_top": float(b[3]), "dlat": dlat,
			"ny": int(ceil((float(b[3]) - float(b[1])) / dlat)) + 1}
	else:
		_err("[TerrainDem] --grid or --bbox is required")
		return {}
	if int(g["nx"]) < 2 or int(g["ny"]) < 2 or float(g["dlon"]) <= 0.0 or float(g["dlat"]) <= 0.0:
		_err("[TerrainDem] empty grid %s" % str(g))
		return {}
	if int(g["nx"]) * int(g["ny"]) > MAX_SAMPLES:
		_err("[TerrainDem] %d × %d nodes is past %d: zoom in or raise the pitch"
				% [g["nx"], g["ny"], MAX_SAMPLES])
		return {}
	g["pitch_m"] = float(g["dlat"]) * data.radius * PI / 180.0
	return g


## Which pyramid level, and which LOD gate, a pitch reads — what the game does for a terrain
## grid of that pitch. A pitch at most twice the finest terrain vertex pitch reads the export
## level with the full relief: PlanetData.grade_height_sampler itself, what the road and railway
## profiles read. A coarser pitch reads the coarsest level whose texels are still finer than it,
## with the relief's octaves finer than the pitch dropped (a coarse LOD's ground).
func _level_for(data: PlanetData, pitch_m: float) -> Dictionary:
	if pitch_m <= 2.0 * data.terrain_vertex_spacing_m():
		return {"nside": data.export_nside, "vtx_spacing_m": 0.0, "exact": true,
			"sampler": "PlanetData.grade_height_sampler (export n%d)" % data.export_nside}
	var ns := data.export_nside
	var res := maxi(data.chunk_heightmap_res, 1)
	while ns > data.export_nside_min \
			and HEALPix.pixel_side_length(ns >> 1, data.radius) / res <= pitch_m:
		ns >>= 1
	return {"nside": ns, "vtx_spacing_m": pitch_m, "exact": false,
		"sampler": "LOD n%d, relief gated at %.0f m" % [ns, pitch_m]}


## The reference the self-check compares the grid with: at the export level with vtx 0,
## PlanetData.grade_height_sampler itself (its frame unprepared, so the GDScript path — the
## grid was sampled by the C# twin, the check proves them equal); else the same call through
## an unprepared frame.
func _sampler(data: PlanetData, ns: int, vtx: float) -> Callable:
	if ns == data.export_nside and vtx == 0.0:
		return data.grade_height_sampler()
	var frame := data.make_tile_frame()
	return func(dir: Vector3) -> float:
		return data.sample_height_for_direction(dir, -1, -1, Vector2i(-1, -1), null, ns, frame,
				vtx, CrackCarve.NONE)


## Tiles of level [param ns] under the grid: nodes every quarter of a tile, the last row and
## column, and each tile's eight neighbours (a node near a tile edge reads the next tile).
func _tiles_under(data: PlanetData, grid: Dictionary, ns: int) -> Dictionary:
	var tile_m := HEALPix.pixel_side_length(ns, data.radius)
	var stride := maxi(1, int(tile_m / float(grid["pitch_m"]) / 4.0))
	var nx: int = grid["nx"]
	var ny: int = grid["ny"]
	var xs: Array = range(0, nx, stride)
	if xs.back() != nx - 1:
		xs.append(nx - 1)
	var ys: Array = range(0, ny, stride)
	if ys.back() != ny - 1:
		ys.append(ny - 1)
	var own := {}
	for j: int in ys:
		var lat: float = float(grid["lat_top"]) - j * float(grid["dlat"])
		for i: int in xs:
			var lon: float = float(grid["lon0"]) + i * float(grid["dlon"])
			own[HEALPix.vec2pix_nest(ns, RoadBridge.lonlat_to_dir(lon, lat))] = true
	var out := own.duplicate()
	for ipix: int in own:
		for nb: int in HEALPix.get_neighbors_nest(ns, ipix).values():
			if nb >= 0:
				out[nb] = true
	return out


func _verify_nodes(grid: Dictionary, h: PackedFloat32Array, sampler: Callable) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var nx: int = grid["nx"]
	var ny: int = grid["ny"]
	var worst := 0.0
	for n in _verify:
		var i := rng.randi_range(0, nx - 1)
		var j := rng.randi_range(0, ny - 1)
		var lon: float = float(grid["lon0"]) + i * float(grid["dlon"])
		var lat: float = float(grid["lat_top"]) - j * float(grid["dlat"])
		# Stored as float32: compare with the float32 of the fresh read.
		var fresh := PackedFloat32Array([sampler.call(RoadBridge.lonlat_to_dir(lon, lat))])
		worst = maxf(worst, absf(fresh[0] - h[j * nx + i]))
	return worst


func _write(path: String, values: PackedFloat32Array) -> bool:
	var fh := FileAccess.open(path, FileAccess.WRITE)
	if fh == null:
		_err("[TerrainDem] cannot write %s" % path)
		return false
	fh.big_endian = false
	fh.store_buffer(values.to_byte_array())
	fh.close()
	return true
