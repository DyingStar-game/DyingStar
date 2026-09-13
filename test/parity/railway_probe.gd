extends Node
## Throwaway bench: the railway on tarsis_8, end to end on the real pack.
##
## Warms the profile the way PlanetTerrain does, then for a few finest
## chunks along the line builds the VISUAL mesh (LOD0) and the COLLISION shape
## and checks they describe one surface: bit-identical grid radii, shared-edge
## vertices identical between neighbours, the bed present in both. Prints the
## profile's summary (cuttings / tunnels / viaducts) and the timings.
##
## Run with:
##   godot --headless --path . res://test/parity/railway_probe.tscn
## The planet defaults to tarsis_8; set RAILWAY_PROBE_PLANET=tarsis_3 (any
## body whose pack carries a railway) to bench another one — the manifest
## supplies the radius, the export depth and the tile size. With
## RAILWAY_PROBE_REMOTE=1 the elevation comes from the configured tile
## service (client.ini), the way the game runs: the warm-up is then expected
## to starve on a cold cache, and the probe measures the catch-up — every
## missing tile fetched, then retry_starved_grade_profiles().
## Output: user://railway_probe.txt

static var OUT: FileAccess = null

func say(t: String) -> void:
	if OUT == null:
		OUT = FileAccess.open("user://railway_probe.txt", FileAccess.WRITE)
	OUT.store_line(t)
	OUT.flush()
	print(t)

var NSIDE := 8192


func _ready() -> void:
	var planet := OS.get_environment("RAILWAY_PROBE_PLANET")
	if planet == "":
		planet = "tarsis_8"
	var data := PlanetData.new()
	data.planet_name = planet
	data.chunk_export_depth = 8
	data.chunk_resolution = 32
	data.max_quadtree_depth = 13
	data.chunk_heightmaps_dir = "assets/qgis/export/%s_chunks" % planet
	data.chunk_heightmap_res = 32
	data.apply_chunk_manifest()
	NSIDE = 1 << data.max_quadtree_depth
	say("PROBE planet %s manifest: radius=%.0f export_nside=%d tile_res=%d maxh=%.1f finest n%d" % [
		planet, data.radius, data.export_nside, data.chunk_heightmap_res, data.max_height, NSIDE])
	say("PROBE carve gate: pitch %.2f m <= %.1f m → %s" % [
		data.terrain_vertex_spacing_m(), GradeSettings.CARVE_MAX_VTX_SPACING_M,
		str(GradeBed.carve_enabled(data, NSIDE, data.terrain_vertex_spacing_m()))])
	say("PROBE has_railways=%s collision_detail_nside=%d vtx_spacing=%.2f m" % [
		str(data.has_railways()), data.collision_detail_nside(), data.terrain_vertex_spacing_m()])

	if OS.get_environment("RAILWAY_PROBE_REMOTE") == "1":
		data.remote_source = RemoteTileSource.for_planet(planet)
		say("PROBE remote source: %s" % ("none (service unreachable or not configured)"
				if data.remote_source == null else data.remote_source.base_url))

	var t0 := Time.get_ticks_msec()
	data.get_bridge_spans()
	data.warm_bridge_plans()
	data.warm_grade_profiles()
	say("PROBE warm-up: %d ms — profiles incomplete: %s" % [
			Time.get_ticks_msec() - t0, str(data.grade_profiles_incomplete())])
	if data.grade_profiles_incomplete():
		# The game leaves this to the streaming thread, the worker pool and
		# the periodic retry; here, bring it all to birth now and time it.
		var t1 := Time.get_ticks_msec()
		var wanted := {}
		for entry: Dictionary in data._grade_starved:
			wanted.merge(entry["tiles"])
		var born := data.flush_grade_profiles()
		say("PROBE catch-up: %d starved tile(s) fetched + profiles computed in %d ms, born fids %s, still incomplete: %s" % [
				wanted.size(), Time.get_ticks_msec() - t1, str(born), str(data.grade_profiles_incomplete())])

	var railways: Array = []
	for r in data.get_whole_roads():
		if RailwaySettings.is_railway(r):
			railways.append(r)
	say("PROBE %d railway(s)" % railways.size())
	if railways.is_empty():
		say("FIN")
		get_tree().quit()
		return
	var road: Dictionary = railways[0]
	var fid := int(road["feature_id"])
	var prof := data.get_grade_profile(fid)
	if prof.is_empty():
		say("PROBE no profile for fid %d" % fid)
		say("FIN")
		get_tree().quit()
		return
	_summary(prof)
	# The cost of ONE profile, alone: what warm_grade_profiles pays per line.
	var tc := Time.get_ticks_msec()
	var again := GradeProfile.compute(road, data.grade_height_sampler())
	say("PROBE compute alone: %d ms for %d stations (%s)" % [Time.get_ticks_msec() - tc,
			(again["stations_along"] as PackedFloat64Array).size(), str(again.get("ok"))])

	# Chunks: the line's start, a cutting, a tunnel mouth, a viaduct — whatever
	# the profile has — each with its along-neighbour so shared edges get tested.
	var alongs: Array = [float(prof["along0"]) + 50.0]
	var picked := {}
	for seg in prof["segments"]:
		var k := int(seg["kind"])
		if k != GradeSettings.Kind.GROUND and not picked.has(k):
			picked[k] = true
			alongs.append(float(seg["lo"]) + 2.0)
	var cl: PackedVector2Array = road["centerline"]
	var cum: PackedFloat64Array = road["_cum_lengths"]
	var col_res: int = data.collision_col_res_for(NSIDE)
	for along in alongs:
		var dir := GradeGeom.dir_at(cl, cum, along)
		var ipix := HEALPix.vec2pix_nest(NSIDE, dir)
		var seg := GradeProfile.segment_at(prof, along)
		say("── along %.0f m (%s) ipix %d" % [along, _kind_name(int(seg["kind"])), ipix])
		var a := _build(data, ipix, col_res)
		# The chunk 300 m further along the line, if different: shared edge?
		var dir2 := GradeGeom.dir_at(cl, cum, along + 300.0)
		var ipix2 := HEALPix.vec2pix_nest(NSIDE, dir2)
		if ipix2 != ipix:
			var b := _build(data, ipix2, col_res)
			_shared_edge(a, b)
	say("FIN")
	get_tree().quit()


func _kind_name(k: int) -> String:
	return ["GROUND", "GORGE", "TUNNEL", "BRIDGE"][k]


func _summary(prof: Dictionary) -> void:
	var counts := [0, 0, 0, 0]
	var lengths := [0.0, 0.0, 0.0, 0.0]
	var deepest := 0.0
	var widest_gap := 0.0
	for seg in prof["segments"]:
		var k := int(seg["kind"])
		counts[k] += 1
		lengths[k] += float(seg["hi"]) - float(seg["lo"])
		deepest = maxf(deepest, float(seg["max_depth"]))
		widest_gap = maxf(widest_gap, float(seg["max_gap"]))
	say("PROBE profile fid=%d tracks=%d hw=%.2f m length=%.0f m knots=%d stations=%d" % [
		int(prof["feature_id"]), int(prof["tracks"]), float(prof["hw_m"]),
		float(prof["along1"]) - float(prof["along0"]),
		(prof["knots_along"] as PackedFloat64Array).size(),
		(prof["stations_along"] as PackedFloat64Array).size()])
	for k in 4:
		say("PROBE   %-6s %4d run(s) %9.0f m" % [_kind_name(k), counts[k], lengths[k]])
	say("PROBE   deepest cutting %.1f m, widest gap under the track %.1f m" % [deepest, widest_gap])
	var kz: PackedFloat64Array = prof["knots_z"]
	var zmin := INF
	var zmax := -INF
	for z in kz:
		zmin = minf(zmin, z)
		zmax = maxf(zmax, z)
	say("PROBE   track altitude %.1f .. %.1f m" % [zmin, zmax])
	# The terrain along the line, coarse, next to the track: what the grade
	# rule was up against.
	var sa: PackedFloat64Array = prof["stations_along"]
	var st: PackedFloat64Array = prof["stations_terrain"]
	var line := "PROBE   terrain/track every 2 km:"
	var i := 0
	while i < sa.size():
		line += " %.0f/%.0f" % [st[i], GradeProfile.z_track_at(prof, sa[i])]
		i += 400
	say(line)


## Build both geometries for one chunk and compare their grids.
func _build(data: PlanetData, ipix: int, col_res: int) -> Dictionary:
	var center: Vector3 = PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(NSIDE, ipix) * data.radius)
	var t0 := Time.get_ticks_usec()
	var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(data, NSIDE, ipix, data.chunk_resolution, center)
	var t1 := Time.get_ticks_usec()
	var shape: ConcavePolygonShape3D = PlanetChunk.generate_collision_shape_healpix(data, NSIDE, ipix, col_res)
	var t2 := Time.get_ticks_usec()
	var res := data.chunk_resolution
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var faces := shape.get_faces()
	var col_origin := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(NSIDE, ipix) * data.radius)
	# Every collision vertex must be a vertex of the visual mesh (grid, patch,
	# bed or tunnel, all surfaces): same origin, same double math, so the
	# float32 positions must match to the millimetre.
	var surfaces := mesh.get_surface_count()
	var mesh_pos := {}
	for si in surfaces:
		for v in (mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
			var w: Vector3 = v + center
			mesh_pos["%.3f_%.3f_%.3f" % [w.x, w.y, w.z]] = true
	var all_mesh := PackedVector3Array()
	for si in surfaces:
		all_mesh.append_array(mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX] as PackedVector3Array)
	var missing := 0
	var missing_grid := 0
	var worst := 0.0
	for fi in faces.size():
		var f := faces[fi]
		var w: Vector3 = f + col_origin
		if mesh_pos.has("%.3f_%.3f_%.3f" % [w.x, w.y, w.z]):
			continue
		# A key miss can be a rounding-boundary artefact: measure for real.
		var best := INF
		for v in all_mesh:
			best = minf(best, (v + center).distance_to(w))
		if best > 1e-3:
			missing += 1
			worst = maxf(worst, best)
			if fi < res * res * 6:
				missing_grid += 1
	say("PROBE   absent (> 1 mm from any mesh vertex): %d in the grid faces, %d in the extras, worst %.4f m" % [
			missing_grid, missing - missing_grid, worst])
	say("PROBE chunk %d: mesh %d ms (%d verts, %d surfaces) | collision %d ms (%d tris) | collision vertices absent from the mesh: %d / %d" % [
		ipix, (t1 - t0) / 1000, verts.size(), surfaces, (t2 - t1) / 1000, faces.size() / 3,
		missing, faces.size()])
	# Bed: the ballast surface is one of the extra surfaces; count its vertices.
	for si in range(1, surfaces):
		var mat := mesh.surface_get_material(si)
		var sv: PackedVector3Array = mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
		say("PROBE   surface %d: %d verts material=%s" % [si, sv.size(),
				mat.resource_path.get_file() if mat and mat.resource_path != "" else str(mat)])
	return {"ipix": ipix, "verts": verts, "center": center, "res": res,
			"faces": faces, "col_origin": col_origin}


## Radii of the vertices two chunks share (positions within 1 mm).
func _shared_edge(a: Dictionary, b: Dictionary) -> void:
	var res: int = a["res"]
	var grid_n := (res + 1) * (res + 1)
	var bpos := {}
	for i in mini(grid_n, (b["verts"] as PackedVector3Array).size()):
		var w: Vector3 = (b["verts"] as PackedVector3Array)[i] + (b["center"] as Vector3)
		bpos["%.2f_%.2f_%.2f" % [w.x, w.y, w.z]] = w
	var shared := 0
	var mism := 0
	for i in mini(grid_n, (a["verts"] as PackedVector3Array).size()):
		var w: Vector3 = (a["verts"] as PackedVector3Array)[i] + (a["center"] as Vector3)
		var key := "%.2f_%.2f_%.2f" % [w.x, w.y, w.z]
		if bpos.has(key):
			shared += 1
			if absf((bpos[key] as Vector3).length() - w.length()) > 1e-3:
				mism += 1
	say("PROBE shared edge %d/%d: %d vertices in common, %d differ in radius" % [
		a["ipix"], b["ipix"], shared, mism])
