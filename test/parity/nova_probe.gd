extends Node
## Nova probe on Tarsis 3: real chunks, built with Nova on.
##   1. a chunk across a frontier between two corundum variants gets Nova vertex channels, a palette
##      holding both, and no separate outcrop surface;
##   2. a fine chunk and its parent lay the same rocks (same cells, same places): the LOD changes the
##      detail of the ground, not where the rocks are.
## Run: godot --headless --path . res://test/parity/nova_probe.tscn

const SCENE := "res://scenes/systems/tarsis/tarsis_3.tscn"
const FINE := 8192


func _ready() -> void:
	var root := (load(SCENE) as PackedScene).instantiate()
	var data: PlanetData = root.get("planet_data")
	data.apply_chunk_manifest()
	data.nova = NovaBody.open_body(data.planet_name)
	print("PROBE variants=%d fingerprint=%s" % [data.nova.variants.size(), data.nova.fingerprint()])

	var tile := _frontier_tile(data)
	if tile < 0:
		print("PROBE FAIL no export tile with two variants")
		get_tree().quit(1)
		return
	var export_nside := data.export_nside
	print("PROBE frontier export tile n%d/%d" % [export_nside, tile])

	# 1. A fine chunk of that tile whose grid holds two variants.
	var per := (FINE / export_nside) * (FINE / export_nside)
	var chunk := -1
	var mesh: ArrayMesh = null
	var t0 := Time.get_ticks_msec()
	for k in range(0, per, 7):
		var ipix := tile * per + k
		var center := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(FINE, ipix) * data.radius)
		var m := PlanetChunk.generate_mesh_healpix(data, FINE, ipix, data.chunk_resolution, center)
		if m.has_meta("nova_vid") and _distinct(m.get_meta("nova_vid")).size() >= 2:
			chunk = ipix
			mesh = m
			break
	if mesh == null:
		print("PROBE FAIL no fine chunk across the frontier")
		get_tree().quit(1)
		return
	print("PROBE chunk n%d/%d built in %d ms, grid variants %s" % [FINE, chunk, Time.get_ticks_msec() - t0,
			_distinct(mesh.get_meta("nova_vid"))])
	var fmt := mesh.surface_get_format(0)
	# The weights ride CUSTOM3 (CUSTOM2 is the LOD morph's); the palette is the mesh's, one per chunk.
	var has_c3 := (fmt & Mesh.ARRAY_FORMAT_CUSTOM3) != 0
	var has_pal := mesh.has_meta("nova_palette")
	print("PROBE surfaces=%d weights=%s palette=%s" % [mesh.get_surface_count(), has_c3,
			mesh.get_meta("nova_palette") if has_pal else "none"])
	var ok := has_c3 and has_pal and mesh.get_surface_count() >= 1
	for s in mesh.get_surface_count():
		var mat := mesh.surface_get_material(s)
		if mat != null and mat.resource_path.contains("corundum_outcrop_surface"):
			print("PROBE FAIL the outcrop surface is still split off")
			ok = false

	# 2. Parent and children lay the same rocks.
	# The probe's own layer, in memory only: no body ships demo rocks.
	var layer := data.nova.profile_for_edit(NovaBody.body_biome_path("tarsis_3", "outcrop-plateau"))
	var rocks := "res://scenes/planet/cave/assets/rock_exterior/"
	for kv: Array in [["enabled", true], ["cell_m", 14.0], ["density", 0.25], ["scale_min", 0.4],
			["scale_max", 1.3], ["meshes", [rocks + "exterior_block_01.tres", rocks + "exterior_block_02.tres",
			rocks + "exterior_erratic_01.tres", rocks + "exterior_slab_01.tres"]]]:
		layer.set_own("scatter/s1/" + str(kv[0]), kv[1])
	var descs := NovaScatter.layer_descs(data.nova, data.radius)
	print("PROBE scatter layers=%d" % descs.size())
	if descs.is_empty():
		print("PROBE FAIL no scatter layer")
		get_tree().quit(1)
		return
	var parent := chunk / 4
	var parent_dirs := _laid_dirs(data, descs, FINE / 2, parent)
	var child_dirs: Array[Vector3] = []
	for c in 4:
		child_dirs.append_array(_laid_dirs(data, descs, FINE, parent * 4 + c))
	var matched := 0
	var worst := 0.0
	for d in child_dirs:
		var best := INF
		for p in parent_dirs:
			best = minf(best, d.angle_to(p) * data.radius)
		if best < 0.5:
			matched += 1
			worst = maxf(worst, best)
	var share := float(matched) / maxf(child_dirs.size(), 1.0)
	print("PROBE rocks parent=%d children=%d matched=%.1f%% worst lateral offset=%.3f m" % [parent_dirs.size(),
			child_dirs.size(), share * 100.0, worst])
	ok = ok and child_dirs.size() > 0 and share > 0.9
	print("PROBE %s" % ("OK" if ok else "FAIL"))
	root.free()
	get_tree().quit(0 if ok else 1)


## An export tile whose zones name at least two variants (a partial record on a frontier).
func _frontier_tile(data: PlanetData) -> int:
	var pack := NovaBody.pack_for(data.planet_name)
	for ipix in pack.get_tile_ipix(data.export_nside):
		var zones: Array = pack.decode_tile(pack.read_tile(data.export_nside, ipix), 0.0,
				ModifierPack.MASK_POPULATE).populate_zones
		var ids := {}
		for z: Dictionary in zones:
			ids[data.nova.variant_id_for_zone(z)] = true
		if ids.size() >= 2:
			pack.close()
			return ipix
	pack.close()
	return -1


func _laid_dirs(data: PlanetData, descs: Array, nside: int, ipix: int) -> Array[Vector3]:
	var center := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(nside, ipix) * data.radius)
	var mesh := PlanetChunk.generate_mesh_healpix(data, nside, ipix, data.chunk_resolution, center)
	var out: Array[Vector3] = []
	if not mesh.has_meta("nova_grid"):
		return out
	var laid := NovaScatter.lay_chunk(descs, nside, ipix, int(mesh.get_meta("nova_res")),
			mesh.get_meta("nova_grid"), mesh.get_meta("nova_vid"), center,
			NovaScatter.zone_context(data, nside, ipix))
	for rows: PackedFloat32Array in laid.values():
		for i in range(0, rows.size(), NovaScatter.ROW):
			out.append((center + Vector3(rows[i + 3], rows[i + 7], rows[i + 11])).normalized())
	return out


func _distinct(vid: PackedInt32Array) -> Array:
	var d := {}
	for v in vid:
		d[v] = true
	var k := d.keys()
	k.sort()
	return k
