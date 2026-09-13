extends Node
## Along tarsis_8's graded road: at each LOD, how many terrain grid vertices
## inside the bed's band stand ABOVE the bed top (terrain piercing the bed)?
## Run: godot --headless --path . res://test/parity/road_bed_probe.tscn
func _ready() -> void:
	var data := PlanetData.new()
	data.planet_name = "tarsis_8"
	data.chunk_export_depth = 8
	data.chunk_resolution = 32
	data.max_quadtree_depth = 13
	data.chunk_heightmaps_dir = "assets/qgis/export/tarsis_8_chunks"
	data.chunk_heightmap_res = 32
	data.apply_chunk_manifest()
	data.warm_grade_profiles()
	var road := {}
	for r in data.get_whole_roads():
		if RoadTerrain.is_graded_road(r):
			road = r
			break
	if road.is_empty():
		print("PROBE no graded road"); get_tree().quit(); return
	var fid := int(road["feature_id"])
	var prof := data.get_grade_profile(fid)
	print("PROBE road fid=%d type=%s slope=%s profile_ok=%s hw=%.2f len=%.0f m" % [fid, road["road_type"],
		str(road.get("max_slope_degrees")), str(not prof.is_empty()), float(prof.get("hw_m", 0.0)),
		float(prof.get("along1", 0.0)) - float(prof.get("along0", 0.0))])
	var kinds := {}
	for seg in prof.get("segments", []):
		kinds[int(seg["kind"])] = kinds.get(int(seg["kind"]), 0) + 1
	print("PROBE segments by kind (0 ground,1 gorge,2 tunnel,3 bridge): %s" % [kinds])
	var cl: PackedVector2Array = road["centerline"]
	var cum: PackedFloat64Array = road["_cum_lengths"]
	var mpd := data.radius * PI / 180.0
	for nside in [8192, 4096, 2048]:
		var seen := {}
		var pierce := 0
		var inband := 0
		var worst := 0.0
		var chunks := 0
		var s := float(prof["along0"])
		while s < float(prof["along1"]):
			var d := GradeGeom.dir_at(cl, cum, s)
			var ipix := HEALPix.vec2pix_nest(nside, d)
			s += 200.0
			if seen.has(ipix):
				continue
			seen[ipix] = true
			chunks += 1
			if chunks > 12:
				break
			var center := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(nside, ipix) * data.radius)
			var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(data, nside, ipix, data.chunk_resolution, center)
			var grid: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			var pieces := [road]
			if nside == 8192:
				print("PROBE   chunk %d: surfaces=%d vertices=%d (33x33 grid = 1089; the rest = skirts + refinement patch)" % [
					ipix, mesh.get_surface_count(), grid.size()])
			for vi in grid.size():   # coarse grid, skirts AND refinement patch
				var w: Vector3 = grid[vi] + center
				var hit := GradeGeom.nearest_on_pieces(pieces, HEALPix.vec2lonlat(w.normalized()), mpd)
				if not hit.get("hit", false):
					continue
				if absf(float(hit["lat_m"])) > float(prof["hw_m"]):
					continue
				var seg := GradeProfile.segment_at(prof, float(hit["along"]))
				if int(seg["kind"]) == GradeSettings.Kind.TUNNEL:
					continue
				inband += 1
				var zt := GradeProfile.z_track_at(prof, float(hit["along"]))
				var h := w.length() - data.radius
				if h > zt + 0.1:
					pierce += 1
					worst = maxf(worst, h - zt)
					if nside == 8192:
						print("PROBE     pierce chunk %d vi=%d (coarse<1089) along=%.0f lat=%.2f kind=%d h-zt=%.2f" % [
							ipix, vi, float(hit["along"]), float(hit["lat_m"]), int(seg["kind"]), h - zt])
		print("PROBE n%d: %d chunks, %d vertices in bed band, %d pierce the bed, worst +%.2f m" % [nside, chunks, inband, pierce, worst])
	get_tree().quit()
