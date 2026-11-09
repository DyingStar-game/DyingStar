extends Node
## How close a LavaSummary (wet mask + Voronoi seeds) comes to the simulation it summarises, on a real Tarsis III
## volcano through a 40 min eruption at full strength and its cleanup: payload size, the error of what the
## renderer reads (depth, glow, crust, fade) at several moments and seed spacings, and top-down images
## (left: simulation, right: rebuilt from the summary).
##
##   godot --headless --path . res://test/lava/lava_summary_probe.tscn -- --out=/tmp/lava-summary [--saved]
## --saved reuses the checkpoints and seeds a previous run wrote in --out, without simulating again.

const Core = preload("res://scenes/planet/lava/lava_fixed_core.gd")
const Builder = preload("res://scenes/planet/lava/lava_planet_patch.gd")
const Summary = preload("res://scenes/planet/lava/lava_summary.gd")
const VOLCANO := "@-39.562632,24.416774"
## [flank spacing (m), crater spacing (sectors)] of each summary compared; the game uses 150 m and 6.
const SPACINGS := [[100.0, 4], [150.0, 6], [250.0, 8]]
const SNAPSHOTS := [3000, 9000, 18000, 24000, 25800, 26700]
const IMAGE_SPACING := 150.0
const SIDE := 512


func _ready() -> void:
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.get_slice("=", 1)
	return fallback


func _run() -> void:
	var out_dir := _arg("out", "user://lava-summary")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var data: PlanetData = SystemScenes.root_properties("res://scenes/systems/tarsis/tarsis_3.tscn").planet_data.duplicate(true)
	data.apply_chunk_manifest()
	data.ensure_queries_loaded()
	data.warm_mountains()
	var volcano: VolcanoRelief.Volcano = null
	for ip in 12:
		for v: VolcanoRelief.Volcano in data.get_chunk_volcanoes(1, ip):
			if VolcanoFeatures.key_of(v) == VOLCANO:
				volcano = v
	var packet := Builder.build(data, volcano)
	var plan := Builder.eruption_plan({"start_unix": 1800000000.0, "length_s": 2400.0, "strength": 1.6}, packet)
	var core = Core.new()
	core.restore(packet.checkpoint)
	var positions := Summary.cell_positions(core)
	var summaries := []
	for s: Array in SPACINGS:
		summaries.append(Summary.new(s[0], s[1]))
	print("PROBE %s field %.0f m, %d x %d cells, checkpoint %d B deflated" % [VOLCANO, float(packet.field_radius_m),
		core.width, core.height, (packet.checkpoint as PackedByteArray).compress(FileAccess.COMPRESSION_DEFLATE).size()])
	if "--saved" in OS.get_cmdline_user_args():
		# Snapshots of a previous run: the reconstruction alone, without simulating again.
		for tick: int in SNAPSHOTS:
			core.restore(FileAccess.get_file_as_bytes(out_dir.path_join("cp_%d.bin" % tick)))
			# Seeds grown at each saved moment only: same density as along the run, a coarser order.
			for summary in summaries:
				summary.grow(core)
			_snapshot(core, summaries, positions, out_dir)
		get_tree().quit(0)
		return
	var started := Time.get_ticks_msec()
	var last := int(SNAPSHOTS[-1])
	while core.tick < last:
		var next: int = core.tick + 1
		if not core.advance_tick(next, Builder.eruption_commands(core, packet, plan, next)):
			print("PROBE FAIL tick %d refused" % next)
			break
		if next % 50 == 0:
			for summary in summaries:
				summary.grow(core)
		if next in SNAPSHOTS:
			_save(out_dir.path_join("cp_%d.bin" % next), core.checkpoint())
			for summary in summaries:
				_save(out_dir.path_join("seeds_%d_%d.bin" % [int(summary.spacing_m), next]), summary.seeds.to_byte_array())
			_snapshot(core, summaries, positions, out_dir)
		if next % 3000 == 0:
			print("PROBE tick %d, %d s" % [next, (Time.get_ticks_msec() - started) / 1000])
	get_tree().quit(0)


func _save(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)


func _snapshot(core, summaries: Array, positions: PackedVector2Array, out_dir: String) -> void:
	var truth := _truth(core)
	var checkpoint_size: int = core.checkpoint().compress(FileAccess.COMPRESSION_DEFLATE).size()
	var grid := Summary.decode_grid(Summary.encode_grid(core))
	var bed_ok: bool = not grid.is_empty() and (grid.radial_edges_mm as PackedInt64Array) == core.radial_edges_mm
	if bed_ok:
		for i in (grid.bed as PackedFloat64Array).size():
			bed_ok = bed_ok and absf(grid.bed[i] - core.terrain_q[i] / 1000.0) <= 0.0051
	print("PROBE grid round trip: %s" % ("exact to the cm" if bed_ok else "FAIL"))
	print("PROBE --- %.1f min: %d wet cells, checkpoint %d B deflated (%d B base64), grid %d B" % [core.tick / 600.0,
		truth.wet_count, checkpoint_size, _b64(checkpoint_size), Summary.encode_grid(core).size()])
	for summary in summaries:
		var t0 := Time.get_ticks_usec()
		var bytes: PackedByteArray = summary.encode(core)
		var t1 := Time.get_ticks_usec()
		var bed := PackedFloat64Array()
		for h: int in core.terrain_q:
			bed.append(h / 1000.0)
		var rebuilt := Summary.reconstruct(bytes, positions, bed)
		var t2 := Time.get_ticks_usec()
		var err := _errors(truth, rebuilt, core)
		var line := "PROBE spacing %3.0f m: %4d seeds, %5d B (%5d B base64), encode %.0f ms, rebuild %.0f ms"
		line += " | depth MAE %.2f m (%.0f %%; crater %.1f m %.0f %%, flanks %.2f m %.0f %%), glow %.3f, crust %.3f, fade %.3f, mask %s"
		print(line % [
			summary.spacing_m, summary.seeds.size(), bytes.size(), _b64(bytes.size()), (t1 - t0) / 1000.0,
			(t2 - t1) / 1000.0, err.depth, err.depth_rel * 100.0, err.crater, err.crater_rel * 100.0, err.flank,
			err.flank_rel * 100.0, err.glow, err.crust, err.opacity,
			"exact" if err.mask_diff == 0 else "%d cells differ" % err.mask_diff])
		if is_equal_approx(summary.spacing_m, IMAGE_SPACING) and summary.seeds.size() > 0:
			_images(core, truth, rebuilt, positions, out_dir, "%02.0fmin" % (core.tick / 600.0))


func _b64(n: int) -> int:
	return (n + 2) / 3 * 4


## What the renderer reads per cell, from the simulation itself.
func _truth(core) -> Dictionary:
	var count: int = core.width * core.height
	var wet := PackedByteArray()
	wet.resize(count)
	var fields := {}
	for key in ["depth", "temperature", "age", "opacity"]:
		var values := PackedFloat64Array()
		values.resize(count)
		fields[key] = values
	var depth: PackedFloat64Array = fields.depth
	var temperature: PackedFloat64Array = fields.temperature
	var age: PackedFloat64Array = fields.age
	var opacity: PackedFloat64Array = fields.opacity
	var wet_count := 0
	for i in count:
		var v := Summary.cell_values(core, i)
		if v.is_empty():
			continue
		wet[i] = 1
		wet_count += 1
		depth[i] = v.depth
		temperature[i] = v.temperature
		age[i] = v.age
		opacity[i] = v.opacity
	return {"wet": wet, "depth": depth, "temperature": temperature, "age": age, "opacity": opacity,
		"wet_count": wet_count}


static func _glow(temperature: float) -> float:
	return clampf((temperature - 850.0) / 350.0, 0.0, 1.0)


static func _crust(temperature: float, age: float) -> float:
	var crust := clampf(1.0 - exp(-age / 55.0), 0.0, 0.94)
	return maxf(crust, 1.0 - clampf((temperature - 950.0) / 150.0, 0.0, 1.0))


func _errors(truth: Dictionary, rebuilt: Dictionary, core) -> Dictionary:
	var sums := {"depth": 0.0, "glow": 0.0, "crust": 0.0, "opacity": 0.0}
	var depth_total := 0.0
	var n := 0
	var zone_err := [0.0, 0.0]
	var zone_total := [0.0, 0.0]
	var zone_n := [0, 0]
	var mask_diff := 0
	for i in (truth.wet as PackedByteArray).size():
		if truth.wet[i] != rebuilt.wet[i]:
			mask_diff += 1
		if truth.wet[i] == 0:
			continue
		n += 1
		sums.depth += absf(truth.depth[i] - rebuilt.depth[i])
		depth_total += truth.depth[i]
		var zone := Summary.zone_of(i, core.width, core.crater_rows)
		zone_err[zone] += absf(truth.depth[i] - rebuilt.depth[i])
		zone_total[zone] += truth.depth[i]
		zone_n[zone] += 1
		sums.glow += absf(_glow(truth.temperature[i]) - _glow(rebuilt.temperature[i]))
		sums.crust += absf(_crust(truth.temperature[i], truth.age[i]) - _crust(rebuilt.temperature[i], rebuilt.age[i]))
		sums.opacity += absf(truth.opacity[i] - rebuilt.opacity[i])
	n = maxi(n, 1)
	return {"depth": sums.depth / n, "depth_rel": sums.depth / maxf(depth_total, 0.001), "glow": sums.glow / n,
		"crater": zone_err[1] / maxi(zone_n[1], 1), "crater_rel": zone_err[1] / maxf(zone_total[1], 0.001),
		"flank": zone_err[0] / maxi(zone_n[0], 1), "flank_rel": zone_err[0] / maxf(zone_total[0], 0.001),
		"crust": sums.crust / n, "opacity": sums.opacity / n, "mask_diff": mask_diff}


## Top-down pictures, simulation left, summary right: the lava's look, then its depth.
func _images(core, truth: Dictionary, rebuilt: Dictionary, positions: PackedVector2Array, out_dir: String, label: String) -> void:
	var reach := 600.0
	var max_depth := 0.1
	for i in (truth.wet as PackedByteArray).size():
		if truth.wet[i] == 1:
			reach = maxf(reach, positions[i].length() * 1.1)
			max_depth = maxf(max_depth, truth.depth[i])
	var low := INF
	var high := -INF
	for h: int in core.terrain_q:
		low = minf(low, h / 1000.0)
		high = maxf(high, h / 1000.0)
	var look := Image.create(SIDE * 2, SIDE, false, Image.FORMAT_RGB8)
	var depth_img := Image.create(SIDE * 2, SIDE, false, Image.FORMAT_RGB8)
	for py in SIDE:
		for px in SIDE:
			var p := (Vector2(px, py) / SIDE * 2.0 - Vector2.ONE) * reach
			var i := _cell_at(core, p)
			for half in 2:
				var fields: Dictionary = truth if half == 0 else rebuilt
				var look_c := Color(0.1, 0.1, 0.12)
				var depth_c := Color(0.05, 0.05, 0.15)
				if i >= 0:
					var g := lerpf(0.25, 0.65, (core.terrain_q[i] / 1000.0 - low) / maxf(high - low, 1.0))
					look_c = Color(g, g, g)
					if fields.wet[i] == 1:
						var temperature: float = fields.temperature[i]
						var hot := Color(1.0, 0.42, 0.06) * (0.35 + 0.9 * _glow(temperature))
						var lava := hot.lerp(Color(0.07, 0.06, 0.06), _crust(temperature, fields.age[i]))
						look_c = look_c.lerp(lava, clampf(fields.opacity[i], 0.0, 1.0))
						var d := clampf(fields.depth[i] / max_depth, 0.0, 1.0)
						depth_c = Color(d, d, d)
				look.set_pixel(px + half * SIDE, py, look_c)
				depth_img.set_pixel(px + half * SIDE, py, depth_c)
	look.save_png(out_dir.path_join("lava_%s_look.png" % label))
	depth_img.save_png(out_dir.path_join("lava_%s_depth.png" % label))
	print("PROBE images %s: %.0f m across, depth white = %.1f m" % [label, reach * 2.0, max_depth])


func _cell_at(core, p: Vector2) -> int:
	if core.geometry_mode != 1:
		return -1
	var r := p.length()
	var edges: PackedInt64Array = core.radial_edges_mm
	if r * 1000.0 >= edges[-1]:
		return -1
	var z := 0
	while z + 1 < edges.size() and edges[z + 1] <= r * 1000.0:
		z += 1
	var a := fposmod(atan2(p.y, p.x), TAU)
	return z * core.width + mini(floori(a * core.width / TAU), core.width - 1)
