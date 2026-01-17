class_name DebugChunkExporter
extends Node
## Press F10 to export the 10 closest chunks' meshes as OBJ files
## and their heightmap images as EXR files for debugging in Blender.
##
## Attach this node as a child of PlanetTerrain (or any node),
## then set [member terrain] to point to the PlanetTerrain node.
## The exported files go to user://debug_chunks/.

## Reference to the PlanetTerrain node (set in inspector or code).
@export var terrain: PlanetTerrain
## Number of closest chunks to export.
@export var chunk_count: int = 10
## Key to trigger export.
@export var trigger_action: Key = KEY_F10

var _export_dir: String = "user://debug_chunks/"


func _ready() -> void:
	Globals.log("[DebugChunkExporter] Ready — press F10 to export chunks")


## Recursively collect every PlanetTerrain node in the scene tree.
func _find_all_planet_terrains(root: Node) -> Array:
	var out: Array = []
	if root is PlanetTerrain:
		out.append(root)
	for child in root.get_children():
		out.append_array(_find_all_planet_terrains(child))
	return out


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var code: int = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
		if code == trigger_action:
			Globals.log("[DebugChunkExporter] F10 pressed — starting export")
			_do_export()


func _do_export() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		push_warning("DebugChunkExporter: no active Camera3D")
		return

	var cam_pos := cam.global_position

	# Pick the PlanetTerrain whose closest active chunk is nearest the camera.
	# The exporter lives under one specific PlanetTerrain in base_planet.tscn,
	# but the player may be standing on a different planet (each system planet
	# has its own PlanetTerrain instance).  Scanning the whole tree and
	# choosing by distance lets F10 always export from "the planet under you".
	var best_terrain: PlanetTerrain = null
	var best_dist := INF
	var all_terrains := _find_all_planet_terrains(get_tree().root)
	for pt in all_terrains:
		var pt_active: Dictionary = pt._active_chunks
		if pt_active.is_empty():
			continue
		for key in pt_active:
			var mi_check: MeshInstance3D = pt_active[key].get("mesh_instance")
			if mi_check == null:
				continue
			var d := cam_pos.distance_to(mi_check.global_position)
			if d < best_dist:
				best_dist = d
				best_terrain = pt
				break  # first chunk is enough to rank the terrain

	if best_terrain == null:
		var names := PackedStringArray()
		for pt in all_terrains:
			names.append("%s(active=%d)" % [pt.name, pt._active_chunks.size()])
		push_warning("DebugChunkExporter: no PlanetTerrain has active chunks — scanned %d: [%s]" % [
			all_terrains.size(), ", ".join(names)])
		return

	terrain = best_terrain
	Globals.log("[DebugExport] Selected terrain '%s' (closest chunk dist=%.0f, active=%d)" % [
		terrain.name, best_dist, terrain._active_chunks.size()])

	var active: Dictionary = terrain._active_chunks

	# Sort by distance to camera
	var sorted_keys: Array = []
	for key in active:
		var info: Dictionary = active[key]
		var mi: MeshInstance3D = info.get("mesh_instance")
		if mi == null:
			continue
		var dist := cam_pos.distance_to(mi.global_position)
		sorted_keys.append({"key": key, "dist": dist, "info": info})

	sorted_keys.sort_custom(func(a, b): return a.dist < b.dist)

	var count := mini(chunk_count, sorted_keys.size())
	Globals.log("[DebugExport] Exporting %d closest chunks to %s" % [count, _export_dir])

	# Create output directory
	DirAccess.make_dir_recursive_absolute(_export_dir)

	for i in count:
		var entry: Dictionary = sorted_keys[i]
		var info: Dictionary = entry.info
		var key: String = entry.key
		var mi: MeshInstance3D = info.mesh_instance
		var dist: float = entry.dist

		Globals.log("[DebugExport] [%d/%d] %s  dist=%.0f" % [i + 1, count, key, dist])

		# ── Export mesh as OBJ ──
		_export_mesh_obj(mi, key, info)

		# ── Export heightmap image ──
		_export_heightmap(info, key)

		# ── Export raw height samples ──
		_export_height_samples(info, key)

	Globals.log("[DebugExport] Done! Files in: %s" % [
		ProjectSettings.globalize_path(_export_dir)])


## Export the mesh attached to a MeshInstance3D as a Wavefront OBJ file.
## Produces two files: one with all geometry (grid + skirt), and one
## with only the terrain grid (no skirt) for clean Blender inspection.
func _export_mesh_obj(mi: MeshInstance3D, key: String, info: Dictionary) -> void:
	var mesh: Mesh = mi.mesh
	if mesh == null:
		return

	var path := _export_dir + key + ".obj"
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa == null:
		push_warning("DebugExport: cannot write %s" % path)
		return

	var chunk_pos: Vector3 = mi.global_position

	# Determine grid vertex count from LOD resolution.
	# Grid is (res+1)² vertices; everything after is skirt.
	var lod: int = info.get("lod", 0)
	var res: int = 32  # LOD 0 default
	if terrain and terrain.planet_data:
		res = terrain.planet_data.get_resolution_for_lod(lod)
	var grid_vert_count := (res + 1) * (res + 1)

	fa.store_line("# DebugChunkExporter — %s" % key)
	fa.store_line("# chunk_center = %s" % str(chunk_pos))
	if info.has("nside"):
		fa.store_line("# nside=%d  ipix=%d  lod=%d  res=%d" % [
			info.get("nside", 0), info.get("ipix", 0), lod, res])
	fa.store_line("# grid_vertices = %d  (first %d are terrain, rest are skirt)" % [
		grid_vert_count, grid_vert_count])
	fa.store_line("o %s" % key)

	var total_vert_offset := 0

	# Also open a skirt-free OBJ for clean Blender inspection.
	var path_clean := _export_dir + key + "_no_skirt.obj"
	var fa_clean := FileAccess.open(path_clean, FileAccess.WRITE)
	if fa_clean:
		fa_clean.store_line("# DebugChunkExporter — %s (terrain grid only, no skirt)" % key)
		fa_clean.store_line("# chunk_center = %s" % str(chunk_pos))
		if info.has("nside"):
			fa_clean.store_line("# nside=%d  ipix=%d  lod=%d  res=%d" % [
				info.get("nside", 0), info.get("ipix", 0), lod, res])
		fa_clean.store_line("o %s" % key)

	for surf_idx in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surf_idx)
		if arrays.size() == 0:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms = arrays[Mesh.ARRAY_NORMAL]
		var idxs = arrays[Mesh.ARRAY_INDEX]
		if verts.size() == 0:
			continue

		fa.store_line("# surface %d: %d vertices (%d grid + %d skirt)" % [
			surf_idx, verts.size(), mini(grid_vert_count, verts.size()),
			maxi(verts.size() - grid_vert_count, 0)])

		# Vertices — local-space coords (relative to chunk_pos)
		for vi in verts.size():
			var local := verts[vi]
			fa.store_line("v %.6f %.6f %.6f" % [local.x, local.y, local.z])
			# Clean file: only grid vertices
			if fa_clean and vi < grid_vert_count:
				fa_clean.store_line("v %.6f %.6f %.6f" % [local.x, local.y, local.z])

		# Normals
		if norms != null and norms is PackedVector3Array:
			for ni in norms.size():
				fa.store_line("vn %.6f %.6f %.6f" % [norms[ni].x, norms[ni].y, norms[ni].z])
				if fa_clean and ni < grid_vert_count:
					fa_clean.store_line("vn %.6f %.6f %.6f" % [norms[ni].x, norms[ni].y, norms[ni].z])

		# Faces (OBJ is 1-indexed)
		if idxs != null and idxs is PackedInt32Array and idxs.size() >= 3:
			for fi in range(0, idxs.size(), 3):
				var i0: int = idxs[fi] + 1 + total_vert_offset
				var i1: int = idxs[fi + 1] + 1 + total_vert_offset
				var i2: int = idxs[fi + 2] + 1 + total_vert_offset
				var line: String
				if norms != null:
					line = "f %d//%d %d//%d %d//%d" % [i0, i0, i1, i1, i2, i2]
				else:
					line = "f %d %d %d" % [i0, i1, i2]
				fa.store_line(line)
				# Clean file: only faces referencing grid vertices
				if fa_clean:
					var max_idx := maxi(idxs[fi], maxi(idxs[fi + 1], idxs[fi + 2]))
					if max_idx < grid_vert_count:
						fa_clean.store_line(line)

		total_vert_offset += verts.size()

	fa.close()
	if fa_clean:
		fa_clean.close()
	Globals.log("  → OBJ: %s  (%d verts, %d grid + %d skirt)" % [
		ProjectSettings.globalize_path(path), total_vert_offset,
		mini(grid_vert_count, total_vert_offset),
		maxi(total_vert_offset - grid_vert_count, 0)])
	Globals.log("  → OBJ (no skirt): %s" % ProjectSettings.globalize_path(path_clean))


## Export the cached heightmap Image for this chunk as EXR (float) + PNG (visual).
func _export_heightmap(info: Dictionary, key: String) -> void:
	if terrain.planet_data == null:
		return

	var ipix: int = info.get("ipix", -1)
	if ipix < 0:
		return

	var img: Image = terrain.planet_data.load_chunk_heightmap(ipix)
	if img == null:
		Globals.log("  → heightmap: not cached (recipe not loaded yet)")
		return

	# Save as EXR (preserves float32 precision)
	var exr_path := _export_dir + key + "_heightmap.exr"
	var err := img.save_exr(exr_path)
	if err == OK:
		Globals.log("  → EXR: %s  (%dx%d)" % [
			ProjectSettings.globalize_path(exr_path), img.get_width(), img.get_height()])
	else:
		push_warning("DebugExport: EXR save failed: %s" % error_string(err))

	# Also save a normalized PNG for quick visual inspection
	var w := img.get_width()
	var h := img.get_height()
	var min_v := INF
	var max_v := -INF
	for y in h:
		for x in w:
			var v := img.get_pixel(x, y).r
			min_v = minf(min_v, v)
			max_v = maxf(max_v, v)

	if max_v > min_v:
		var vis := Image.create(w, h, false, Image.FORMAT_L8)
		for y in h:
			for x in w:
				var v := img.get_pixel(x, y).r
				var n := (v - min_v) / (max_v - min_v)
				vis.set_pixel(x, y, Color(n, n, n, 1.0))
		var png_path := _export_dir + key + "_heightmap.png"
		vis.save_png(png_path)
		Globals.log("  → PNG: %s  (range %.2f–%.2f)" % [
			ProjectSettings.globalize_path(png_path), min_v, max_v])


## Export a CSV of height values sampled at a regular grid across the chunk.
## This lets you plot height vs position in a spreadsheet and see if
## there are discrete steps / plateaus.
func _export_height_samples(info: Dictionary, key: String) -> void:
	if terrain.planet_data == null:
		return

	var nside: int = info.get("nside", 0)
	var ipix: int = info.get("ipix", -1)
	if ipix < 0 or nside <= 0:
		return

	var data: PlanetData = terrain.planet_data
	var sample_res := 64  # 64×64 sample grid for analysis

	var path := _export_dir + key + "_heights.csv"
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa == null:
		return

	# Walk chunk ipix down to export_nside so sample_height_for_direction
	# receives a valid export-level pixel index, not the chunk-level one.
	var export_ipix := ipix
	var cur_nside := nside
	while cur_nside > data.export_nside:
		@warning_ignore("integer_division")
		export_ipix = export_ipix / 4
		@warning_ignore("integer_division")
		cur_nside = cur_nside / 2

	fa.store_line("px,py,height,lon,lat,world_x,world_y,world_z")

	var npface := nside * nside
	@warning_ignore("integer_division")
	var face: int = ipix / npface
	var local := ipix % npface
	var xy := HEALPix.nest2xy(local)
	var ix: int = xy.x
	var iy: int = xy.y
	var sub_nside := nside * sample_res

	for py in sample_res:
		for px in sample_res:
			var sub_ix := ix * sample_res + px
			var sub_iy := iy * sample_res + py
			var dir := HEALPix._face_xy_to_vec(
				face, float(sub_ix) + 0.5, float(sub_iy) + 0.5, sub_nside)
			var height := data.sample_height_for_direction(dir, export_ipix)
			var lonlat := _dir_to_lonlat(dir)
			var world := dir * (data.radius + height)
			fa.store_line("%.6f,%.6f,%.4f,%.6f,%.6f,%.2f,%.2f,%.2f" % [
				px, py, height, lonlat.x, lonlat.y, world.x, world.y, world.z])

	fa.close()
	Globals.log("  → CSV: %s  (%dx%d samples)" % [
		ProjectSettings.globalize_path(path), sample_res, sample_res])


## Convert a unit direction vector to (longitude, latitude) degrees.
static func _dir_to_lonlat(dir: Vector3) -> Vector2:
	var lat := rad_to_deg(asin(clampf(dir.y, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(dir.z, dir.x))
	return Vector2(lon, lat)
