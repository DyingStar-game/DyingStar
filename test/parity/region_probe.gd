extends Node
## Regions probe: does tarsis_8's pack hand a chunk its zones, does the biome
## resolve, does the chunk mesh get the override surface?
## Run: godot --headless --path . res://test/parity/region_probe.tscn
func _ready() -> void:
	var data := PlanetData.new()
	data.planet_name = "tarsis_8"
	data.chunk_export_depth = 8
	data.chunk_resolution = 32
	data.max_quadtree_depth = 13
	data.chunk_heightmaps_dir = "assets/qgis/export/tarsis_8_chunks"
	data.chunk_heightmap_res = 32
	data.apply_chunk_manifest()
	print("PROBE fingerprint=%s" % data.populate_fingerprint())
	var bd = data.get_biome_by_type("outcrop-plateau")
	print("PROBE bd=%s override=%s" % [bd, bd.terrain_material_override if bd else null])
	var zones: Array = data.get_chunk_populate_zones(467551)
	print("PROBE zones@467551=%d" % zones.size())
	for z in zones:
		print("PROBE zone keys=%s biome=%s cov=%s rock=%s" % [z.keys(), z.get("biome_type"), z.get("coverage"), z.get("rock_type")])
	var ipix := 467551
	var center: Vector3 = HEALPix.pix2vec_nest(256, ipix) * data.radius
	var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(data, 256, ipix, data.chunk_resolution, center)
	print("PROBE surfaces=%d" % mesh.get_surface_count())
	for si in mesh.get_surface_count():
		var mat := mesh.surface_get_material(si)
		var arr := mesh.surface_get_arrays(si)
		print("PROBE surface %d mat=%s tris=%d" % [si, mat.resource_path if mat else "none",
				(arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3])
	# Parity mesh / collision at the finest level (the server's fine grid on a
	# planet with relief biomes), on a child chunk INSIDE the plateau (the one
	# whose mesh gets the override surface).
	var nside := 8192
	var base := ipix * (nside / 256) * (nside / 256)
	var res := data.chunk_resolution
	var col_res: int = data.collision_col_res_for(nside)
	var checked := 0
	for k in range(0, 1024, 37):
		var child := base + k
		var center_f := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(nside, child) * data.radius)
		var fine: ArrayMesh = PlanetChunk.generate_mesh_healpix(data, nside, child, res, center_f)
		if fine.get_surface_count() < 2:
			continue
		var shape: ConcavePolygonShape3D = PlanetChunk.generate_collision_shape_healpix(data, nside, child, col_res)
		var faces := shape.get_faces()
		var col_origin := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(nside, child) * data.radius)
		var grid: PackedVector3Array = fine.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var mesh_pos := {}
		var lo := INF
		var hi := -INF
		for vi in (res + 1) * (res + 1):   # grid vertices only, skirts excluded
			var w: Vector3 = grid[vi] + center_f
			mesh_pos["%.3f_%.3f_%.3f" % [w.x, w.y, w.z]] = true
			var d := w.length() - data.crack_aware_surface_dist(w.normalized(), nside)
			lo = minf(lo, d)
			hi = maxf(hi, d)
		var missing := 0
		var worst := 0.0
		var grid_faces := col_res * col_res * 6
		for fi in mini(faces.size(), grid_faces):
			var w: Vector3 = faces[fi] + col_origin
			if mesh_pos.has("%.3f_%.3f_%.3f" % [w.x, w.y, w.z]):
				continue
			var best := INF
			for vi in (res + 1) * (res + 1):
				best = minf(best, (grid[vi] + center_f).distance_to(w))
			if best > 1e-3:
				missing += 1
				worst = maxf(worst, best)
		print("PROBE fine n%d/%d col_res=%d relief_range=[%.2f, %.2f] m collision_vertices_off_mesh=%d worst=%.3f m" % [
			nside, child, col_res, lo, hi, missing, worst])
		checked += 1
		if checked >= 2:
			break
	if checked == 0:
		print("PROBE fine: no child chunk of tile %d lies inside the plateau" % ipix)
	get_tree().quit()
