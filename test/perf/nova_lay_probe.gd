extends Node
## What NovaScatter.lay_chunk costs on the mining village's chunks of tarsis_3, layer by layer, headless:
##   <godot> --headless --path . res://test/perf/nova_lay_probe.tscn [-- ipix=214960188,214960189 nside=8192 gd stages]
## `gd`: the cells through the GDScript twin instead of NovaCellsNative; `stages`: the small layers timed stage by stage.
## The village's pads and beds are registered by its buildings in a game, not here: the clearance is lighter
## than in a session. Prints one line a layer (cells walked, objects laid, ms) and the total per chunk.

const HeadlessPlanet := preload("res://tools/planettech/headless_planet.gd")


func _ready() -> void:
	var args := {}
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var planet := str(args.get("planet", "tarsis_3"))
	var nside := int(args.get("nside", "8192"))
	var ipixes: PackedStringArray = str(args.get("ipix", "214960188,214960189,214960190")).split(",")
	NovaScatter.native_cells = not args.has("gd")
	print("[NovaProbe] cells in %s" % ("GDScript" if args.has("gd") else "C# when it loads"))
	var data := HeadlessPlanet.planet_data(planet)
	data.apply_chunk_manifest()
	data.remote_source = RemoteTileSource.for_planet(planet)
	data.attach_remote_modifiers()
	data.set_crack_exclusions(PlanetTerrain.poi_crack_exclusions(planet))
	data.warm_mountains()
	data.warm_fumaroles()
	var body := NovaBody.open_body(planet)
	data.nova = body
	data.nova_relief = body
	var t := Time.get_ticks_usec()
	var descs: Array = NovaScatter.layer_descs(body, data.radius, data.default_rock(), true)
	print("[NovaProbe] %d layers read in %.0f ms" % [descs.size(), (Time.get_ticks_usec() - t) / 1000.0])
	for ip: String in ipixes:
		var ipix := int(ip)
		var shape := PlanetChunk.generate_collision_shape_healpix(data, nside, ipix, data.collision_col_res_for(nside))
		var grid: PackedVector3Array = shape.get_meta("nova_grid") if shape != null else PackedVector3Array()
		var res := roundi(sqrt(float(grid.size()))) - 1
		var vid := PackedInt32Array()
		vid.resize(grid.size())
		var origin := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(nside, ipix) * data.radius)
		t = Time.get_ticks_usec()
		var zones := NovaScatter.zone_context(data, nside, ipix)
		print("[NovaProbe] n%d p%d grid res %d, zones %.0f ms, candidates %s, clearance %s" % [nside, ipix, res,
				(Time.get_ticks_usec() - t) / 1000.0, str(zones.get("candidates", {}).keys()), zones.has("clearance")])
		var total := 0.0
		var rows: Array = []
		for d: Dictionary in descs:
			var cells := NovaScatter.chunk_cells(nside, ipix, int(d.nside))
			t = Time.get_ticks_usec()
			var laid := NovaScatter.lay_chunk([d], nside, ipix, res, grid, vid, origin, zones)
			var ms := (Time.get_ticks_usec() - t) / 1000.0
			total += ms
			var objects := 0
			for key: Array in laid:
				objects += (laid[key] as Array).size() if laid[key] is Array else 1
			rows.append([ms, "variant %d slot %s view %.0f m nside %d cells %d laid %d (%d blocks): %.0f ms" % [
				int(d.variant), str(d.get("slot", "?")), float(d.view_m), int(d.nside),
				int(cells.get("r", 0)) ** 2, objects, laid.size(), ms]])
		rows.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
		for r: Array in rows:
			if float(r[0]) >= 1.0:
				print("[NovaProbe]   " + str(r[1]))
		print("[NovaProbe] n%d p%d TOTAL %.0f ms over %d layers" % [nside, ipix, total, descs.size()])
		if args.has("stages"):
			for d: Dictionary in descs:
				if float(d.view_m) <= 80.0:
					_stages(d, nside, ipix, res, grid, vid, origin, zones)
	if data.remote_source != null:
		data.remote_source.stop()
	get_tree().quit()


## lay_chunk's cell loop for one layer, timed stage by stage (passes, µs): where a cell's time goes.
func _stages(d: Dictionary, nside: int, ipix: int, _res: int, _grid: PackedVector3Array, _vid: PackedInt32Array,
		_center: Vector3, zones: Dictionary) -> void:
	var fxy := HEALPix.pix2face_xy(nside, ipix)
	var face: int = fxy.face
	var cells := NovaScatter.chunk_cells(nside, ipix, d.nside)
	var r: int = cells.r
	var variant_at: Callable = zones.get("variant_at", Callable())
	var clearance: NovaClearance = zones.get("clearance")
	var us := {"hash": 0, "clump": 0, "dir": 0, "clear": 0, "zone": 0}
	var n := {"cells": 0, "hash": 0, "clump": 0, "clear": 0, "zone": 0}
	for cy in r:
		for cx in r:
			n.cells += 1
			var t0 := Time.get_ticks_usec()
			var o := NovaScatter.cell_object(d.seed, d.density, face, int(cells.x0) + cx, int(cells.y0) + cy)
			var t1 := Time.get_ticks_usec()
			us.hash += t1 - t0
			if o.is_empty():
				continue
			n.hash += 1
			if d.clump_cells > 1 and float(o.u_edge) >= NovaScatter.clump_weight(d.seed, face, float(o.fx),
					float(o.fy), d.clump_cells, d.clump_share):
				us.clump += Time.get_ticks_usec() - t1
				continue
			var t2 := Time.get_ticks_usec()
			us.clump += t2 - t1
			n.clump += 1
			var up := HEALPix._face_xy_to_vec(face, float(o.fx), float(o.fy), d.nside)
			var mi := mini(int(o.u_mesh * d.meshes.size()), d.meshes.size() - 1)
			var sc: float = lerpf(d.scale_min, d.scale_max, o.u_scale)
			var t3 := Time.get_ticks_usec()
			us.dir += t3 - t2
			if clearance != null and float(o.u_keep) >= clearance.share_for(up, float(d.reaches[mi]) * sc, float(o.u_keep)):
				us.clear += Time.get_ticks_usec() - t3
				continue
			var t4 := Time.get_ticks_usec()
			us.clear += t4 - t3
			n.clear += 1
			if variant_at.is_valid():
				var v := int(variant_at.call(NovaScatter._spilled(up, float(o.u_spill_turn), float(o.u_spill_far), d.spill)))
				us.zone += Time.get_ticks_usec() - t4
				if v != d.variant:
					continue
			n.zone += 1
	print("[NovaProbe] stages variant %d slot %s: %s | µs %s" % [int(d.variant), str(d.get("slot")), str(n), str(us)])
