@tool
class_name PlanetVegetation
## Static helpers for scattering vegetation on terrain chunks.
##
## Given a terrain chunk's UV bounds, sample the biomemap at a grid of points.
## For each point that matches a [VegetationRule], add a tree transform.
## Returns a [MultiMesh] ready to attach to a [MultiMeshInstance3D].

## One-shot diagnostic flag (shared across all calls).
static var _diag_done: bool = false
## Counter for geojson scatter logging (first N chunks).
static var _geojson_log_count: int = 0


## Build a [MultiMesh] of vegetation instances for one terrain chunk.
##
## Returns [code]null[/code] if no instances match any rule in this chunk.
## [param chunk_center] — world-space centre of this chunk.  Instance
## transforms are stored *relative* to this point so the
## [MultiMeshInstance3D] can be positioned there, keeping GPU
## float32 values small and avoiding precision loss.
static func scatter_chunk(
		planet_data: PlanetData,
		rules: Array,  # Array[VegetationRule]
		face: int,
		u_min: float, u_max: float,
		v_min: float, v_max: float,
		chunk_center: Vector3 = Vector3.ZERO,
		hp_nside: int = 0,
		hp_ipix: int = -1,
		populate_zones: Array = []) -> MultiMesh:

	var hp_mode := hp_nside > 0

	if rules.is_empty() or planet_data == null:
		return null

	# Prefer populate_zones polygon matching; fall back to biomemap colour.
	var _use_pz := not populate_zones.is_empty()
	var use_geojson: bool = _use_pz

	# One-time diagnostic (first chunk only)
	if not _diag_done:
		_diag_done = true
		var chunk_dir: Vector3
		if hp_mode:
			chunk_dir = HEALPix.pix2vec_nest(hp_nside, hp_ipix)
		else:
			chunk_dir = PlanetData.cube_to_sphere(face,
					(u_min + u_max) * 0.5, (v_min + v_max) * 0.5)
		var lonlat := Vector2(
				rad_to_deg(atan2(chunk_dir.z, chunk_dir.x)),
				rad_to_deg(asin(clampf(chunk_dir.y, -1.0, 1.0))))
		print("[VEG_DIAG] use_geojson=%s  populate_zones=%d  biomemap=%s" % [
			use_geojson, populate_zones.size(), planet_data.get_biomemap_image() != null])
		print("[VEG_DIAG] first chunk: face=%d uv=(%.3f..%.3f, %.3f..%.3f) → lonlat=(%.1f, %.1f)" % [
			face, u_min, u_max, v_min, v_max, lonlat.x, lonlat.y])
		for r: VegetationRule in rules:
			print("[VEG_DIAG] rule '%s': biome_type='%s' spawn_lods=%s mesh=%s scene=%s" % [
				r.rule_name, r.biome_type, r.spawn_lod_levels, r.mesh, r.mesh_scene])

	if not use_geojson and planet_data.get_biomemap_image() == null:
		push_warning("[PlanetVegetation] scatter_chunk: no biome source for '%s'" % planet_data.planet_name)
		return null

	# Collect transforms for every rule
	var all_transforms: Array[Transform3D] = []
	var merged_mesh: Mesh = null

	for rule: VegetationRule in rules:
		var rmesh := _get_rule_mesh(rule)
		if rmesh == null:
			push_warning("[PlanetVegetation] rule '%s': mesh is null (mesh=%s, mesh_scene=%s)" % [
				rule.rule_name, rule.mesh, rule.mesh_scene])
			continue

		var transforms: Array[Transform3D]
		if use_geojson and not rule.biome_type.is_empty():
			transforms = _scatter_for_rule_geojson(planet_data, null,
					rule, face, u_min, u_max, v_min, v_max, chunk_center,
					hp_nside, hp_ipix, populate_zones)
		else:
			transforms = _scatter_for_rule(planet_data, rule, face,
					u_min, u_max, v_min, v_max, chunk_center,
					hp_nside, hp_ipix)
		if transforms.is_empty():
			continue

		# For simplicity we use the first rule's mesh for the whole chunk.
		# Multiple vegetation types per chunk would need separate MultiMeshes;
		# keeping it simple for now — one MultiMesh per chunk with the first
		# matching rule.
		if merged_mesh == null:
			merged_mesh = rmesh
		all_transforms.append_array(transforms)

	if all_transforms.is_empty() or merged_mesh == null:
		return null

	print("[PlanetVegetation] Chunk face=%d: %d instances, mesh surfaces=%d" % [
		face, all_transforms.size(), merged_mesh.get_surface_count()])

	# Build the MultiMesh
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = merged_mesh
	mm.instance_count = all_transforms.size()
	for i in all_transforms.size():
		mm.set_instance_transform(i, all_transforms[i])

	return mm


## Scatter transforms for a single [VegetationRule] across the chunk
## using the biomemap colour matching (legacy / fallback path).
static func _scatter_for_rule(
		planet_data: PlanetData,
		rule: VegetationRule,
		face: int,
		u_min: float, u_max: float,
		v_min: float, v_max: float,
		chunk_center: Vector3 = Vector3.ZERO,
		hp_nside: int = 0,
		hp_ipix: int = -1) -> Array[Transform3D]:

	var hp_mode := hp_nside > 0
	var results: Array[Transform3D] = []

	if planet_data.get_biomemap_image() == null:
		return results

	var grid_steps := _compute_grid_steps(planet_data, rule, face,
			u_min, u_max, v_min, v_max, hp_nside, hp_ipix)

	var rng := RandomNumberGenerator.new()
	if hp_mode:
		rng.seed = hash(Vector2i(hp_nside, hp_ipix))
	else:
		rng.seed = hash(Vector4(u_min, v_min, u_max, v_max))

	# HEALPix pixel face-local coordinates for grid iteration.
	var _hp_face := 0
	var _hp_ix := 0
	var _hp_iy := 0
	if hp_mode:
		var _pxy: Dictionary = HEALPix.pix2face_xy(hp_nside, hp_ipix)
		_hp_face = _pxy["face"]
		_hp_ix = _pxy["ix"]
		_hp_iy = _pxy["iy"]

	# Phase 1: collect candidates that match the biome colour
	var candidates: Array[Vector2] = []
	for yi in grid_steps:
		for xi in grid_steps:
			var dir: Vector3
			var cand: Vector2
			if hp_mode:
				var fx := float(_hp_ix) + (float(xi) + rng.randf()) / float(grid_steps)
				var fy := float(_hp_iy) + (float(yi) + rng.randf()) / float(grid_steps)
				fx = clampf(fx, float(_hp_ix), float(_hp_ix + 1) - 1e-6)
				fy = clampf(fy, float(_hp_iy), float(_hp_iy + 1) - 1e-6)
				dir = HEALPix._face_xy_to_vec(_hp_face, fx, fy, hp_nside)
				cand = Vector2(fx, fy)
			else:
				var u_step := (u_max - u_min) / float(grid_steps)
				var v_step := (v_max - v_min) / float(grid_steps)
				var u := u_min + (xi + rng.randf()) * u_step
				var v := v_min + (yi + rng.randf()) * v_step
				u = clampf(u, u_min, u_max)
				v = clampf(v, v_min, v_max)
				dir = PlanetData.cube_to_sphere(face, u, v)
				cand = Vector2(u, v)

			var biome_col: Color = planet_data.sample_biome_at(dir)
			if rule.matches_color(biome_col):
				candidates.append(cand)

	# Phase 2 & 3: thin + build transforms
	return _finalize_candidates(planet_data, rule, face,
			u_min, u_max, v_min, v_max, candidates, rng, chunk_center,
			hp_nside, hp_ipix)


## Scatter transforms for a single [VegetationRule] across the chunk
## using GeoJSON polygon zones.  Each candidate point is tested against
## the polygon boundaries — no colour sampling needed.
static func _scatter_for_rule_geojson(
		planet_data: PlanetData,
		biome_query,  # BiomeQuery (nullable when populate_zones provided)
		rule: VegetationRule,
		face: int,
		u_min: float, u_max: float,
		v_min: float, v_max: float,
		chunk_center: Vector3 = Vector3.ZERO,
		hp_nside: int = 0,
		hp_ipix: int = -1,
		populate_zones: Array = []) -> Array[Transform3D]:

	var hp_mode := hp_nside > 0
	var _use_pz := not populate_zones.is_empty()

	# ── Chunk-level AABB early exit ─────────────────────────────
	if _use_pz:
		var _has_biome := false
		for _pz in populate_zones:
			if _pz.get("biome_type", "") == rule.biome_type:
				_has_biome = true
				break
		if not _has_biome:
			return []
	elif hp_mode:
		if not biome_query.chunk_overlaps_biome_hp(hp_nside, hp_ipix,
				rule.biome_type):
			return []
	else:
		if not biome_query.chunk_overlaps_biome(face, u_min, u_max,
				v_min, v_max, rule.biome_type):
			return []

	var grid_steps := _compute_grid_steps(planet_data, rule, face,
			u_min, u_max, v_min, v_max, hp_nside, hp_ipix)

	var rng := RandomNumberGenerator.new()
	if hp_mode:
		rng.seed = hash(Vector2i(hp_nside, hp_ipix))
	else:
		rng.seed = hash(Vector4(u_min, v_min, u_max, v_max))

	# HEALPix pixel face-local coordinates for grid iteration.
	var _hp_face := 0
	var _hp_ix := 0
	var _hp_iy := 0
	if hp_mode:
		var _pxy: Dictionary = HEALPix.pix2face_xy(hp_nside, hp_ipix)
		_hp_face = _pxy["face"]
		_hp_ix = _pxy["ix"]
		_hp_iy = _pxy["iy"]

	# Check if this chunk is near the swamp for diagnostic purposes.
	var _mid_d: Vector3
	if hp_mode:
		_mid_d = HEALPix.pix2vec_nest(hp_nside, hp_ipix)
	else:
		_mid_d = PlanetData.cube_to_sphere(face,
				(u_min + u_max) * 0.5, (v_min + v_max) * 0.5)
	var _ll := Vector2(
			rad_to_deg(atan2(_mid_d.z, _mid_d.x)),
			rad_to_deg(asin(clampf(_mid_d.y, -1.0, 1.0))))
	var _near_swamp := absf(_ll.x) < 0.5 and absf(_ll.y) < 0.5

	# Phase 1: collect candidates inside a matching GeoJSON polygon
	var candidates: Array[Vector2] = []
	var _dbg_first_query_result := {}
	for yi in grid_steps:
		for xi in grid_steps:
			var dir: Vector3
			var cand: Vector2
			if hp_mode:
				var fx := float(_hp_ix) + (float(xi) + rng.randf()) / float(grid_steps)
				var fy := float(_hp_iy) + (float(yi) + rng.randf()) / float(grid_steps)
				fx = clampf(fx, float(_hp_ix), float(_hp_ix + 1) - 1e-6)
				fy = clampf(fy, float(_hp_iy), float(_hp_iy + 1) - 1e-6)
				dir = HEALPix._face_xy_to_vec(_hp_face, fx, fy, hp_nside)
				cand = Vector2(fx, fy)
			else:
				var u_step := (u_max - u_min) / float(grid_steps)
				var v_step := (v_max - v_min) / float(grid_steps)
				var u := u_min + (xi + rng.randf()) * u_step
				var v := v_min + (yi + rng.randf()) * v_step
				u = clampf(u, u_min, u_max)
				v = clampf(v, v_min, v_max)
				dir = PlanetData.cube_to_sphere(face, u, v)
				cand = Vector2(u, v)

			var zone: Dictionary = {}
			if _use_pz:
				var _pz_at := PlanetChunk._query_zones_at_direction(dir, populate_zones)
				for _pzz in _pz_at:
					if _pzz.get("biome_type", "") == rule.biome_type:
						zone = _pzz
						break
			elif biome_query:
				zone = biome_query.query_biome_type(dir, rule.biome_type)
			if _near_swamp and _dbg_first_query_result.is_empty() and yi == 0 and xi == 0:
				var lonlat_pt := Vector2(
						rad_to_deg(atan2(dir.z, dir.x)),
						rad_to_deg(asin(clampf(dir.y, -1.0, 1.0))))
				_dbg_first_query_result = {"ll": lonlat_pt, "match": not zone.is_empty()}
			if not zone.is_empty():
				# Apply the zone's density as a probability filter.
				var density: float = zone.get("density", 1.0)
				if density >= 1.0 or rng.randf() < density:
					candidates.append(cand)

	if _near_swamp:
		print("[VEG_SWAMP_DBG] face=%d rule=%s grid=%d candidates=%d/%d lonlat=(%.6f,%.6f) uv=(%.8f..%.8f,%.8f..%.8f) first_query=%s" % [
			face, rule.biome_type, grid_steps, candidates.size(), grid_steps * grid_steps,
			_ll.x, _ll.y, u_min, u_max, v_min, v_max, _dbg_first_query_result])

	# Log the first few chunks so we can diagnose matching issues.
	var mid_dir: Vector3
	if hp_mode:
		mid_dir = HEALPix.pix2vec_nest(hp_nside, hp_ipix)
	else:
		mid_dir = PlanetData.cube_to_sphere(face,
				(u_min + u_max) * 0.5, (v_min + v_max) * 0.5)
	var ll := Vector2(
			rad_to_deg(atan2(mid_dir.z, mid_dir.x)),
			rad_to_deg(asin(clampf(mid_dir.y, -1.0, 1.0))))

	# Always log chunks near the swamp zone (lon≈0, lat≈0) or with candidates.
	var near_swamp := absf(ll.x) < 1.0 and absf(ll.y) < 1.0
	if _geojson_log_count < 40 or candidates.size() > 0 or near_swamp:
		if _geojson_log_count < 40:
			_geojson_log_count += 1
		print("[VEG_GEO] face=%d grid=%d candidates=%d/%d lonlat=(%.4f,%.4f) uv=(%.8f..%.8f,%.8f..%.8f) rule=%s" % [
			face, grid_steps, candidates.size(), grid_steps * grid_steps,
			ll.x, ll.y, u_min, u_max, v_min, v_max, rule.biome_type])

	# Phase 2 & 3: thin + build transforms
	return _finalize_candidates(planet_data, rule, face,
			u_min, u_max, v_min, v_max, candidates, rng, chunk_center,
			hp_nside, hp_ipix)


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

## Compute the grid resolution for candidate scanning.
static func _compute_grid_steps(
		planet_data: PlanetData,
		rule: VegetationRule,
		face: int,
		u_min: float, u_max: float,
		v_min: float, v_max: float,
		hp_nside: int = 0,
		_hp_ipix: int = -1) -> int:
	var chunk_size: float
	if hp_nside > 0:
		chunk_size = HEALPix.pixel_side_length(hp_nside, planet_data.radius)
	else:
		var corner_a := PlanetData.cube_to_sphere(face, u_min, v_min) * planet_data.radius
		var corner_b := PlanetData.cube_to_sphere(face, u_max, v_max) * planet_data.radius
		chunk_size = corner_a.distance_to(corner_b)
	var spacing := maxf(rule.min_spacing, 1.0)
	var grid_from_spacing := clampi(int(chunk_size / spacing), 2, 128)
	var grid_from_budget  := ceili(sqrt(float(rule.max_per_chunk) * 2.5))
	return mini(grid_from_spacing, maxi(grid_from_budget, 2))


## Phase 2+3: thin candidates to max_per_chunk, then build transforms.
static func _finalize_candidates(
		planet_data: PlanetData,
		rule: VegetationRule,
		face: int,
		u_min: float, u_max: float,
		v_min: float, v_max: float,
		candidates: Array[Vector2],
		rng: RandomNumberGenerator,
		chunk_center: Vector3,
		hp_nside: int = 0,
		hp_ipix: int = -1) -> Array[Transform3D]:

	var hp_mode := hp_nside > 0
	# For HEALPix: reconstruct face-local coords for direction lookup.
	var _hp_face := 0
	if hp_mode:
		_hp_face = HEALPix.pix2face_xy(hp_nside, hp_ipix)["face"]

	var results: Array[Transform3D] = []

	# Thin to max_per_chunk via Fisher-Yates partial shuffle
	if candidates.size() > rule.max_per_chunk:
		for i in rule.max_per_chunk:
			var j := rng.randi_range(i, candidates.size() - 1)
			var tmp := candidates[i]
			candidates[i] = candidates[j]
			candidates[j] = tmp
		candidates.resize(rule.max_per_chunk)

	# Build transforms
	for uv in candidates:
		var dir: Vector3
		var height: float
		if hp_mode:
			dir = HEALPix._face_xy_to_vec(_hp_face, uv.x, uv.y, hp_nside)
			height = planet_data.sample_height_for_direction(dir)
		else:
			dir = PlanetData.cube_to_sphere(face, uv.x, uv.y)
			height = planet_data.sample_height_for_chunk(
					face, uv.x, uv.y, u_min, u_max, v_min, v_max)
		var pos := dir * (planet_data.radius + height) - chunk_center

		# Build an oriented transform:  Y-up = surface normal (= dir)
		var up := dir
		var arbitrary := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.99 else Vector3.FORWARD
		var right := up.cross(arbitrary).normalized()
		var forward := right.cross(up).normalized()
		var basis := Basis(right, up, forward)

		if rule.random_yaw:
			var yaw := rng.randf() * TAU
			basis = basis * Basis(Vector3.UP, yaw)

		if rule.max_tilt_deg > 0.0:
			var tilt_axis := Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized()
			var tilt_angle := deg_to_rad(rng.randf_range(0, rule.max_tilt_deg))
			basis = basis * Basis(tilt_axis, tilt_angle)

		var s := rng.randf_range(rule.scale_min, rule.scale_max)
		basis = basis.scaled(Vector3(s, s, s))

		results.append(Transform3D(basis, pos))

	return results


## HEALPix variant of [method scatter_chunk].
static func scatter_chunk_hp(
		planet_data: PlanetData,
		rules: Array,
		nside: int,
		ipix: int,
		chunk_center: Vector3 = Vector3.ZERO,
		populate_zones: Array = []) -> MultiMesh:
	return scatter_chunk(planet_data, rules, 0, 0.0, 0.0, 0.0, 0.0,
			chunk_center, nside, ipix, populate_zones)


## Resolve the mesh for a rule: prefer cached mesh, else merge from scene.
static func _get_rule_mesh(rule: VegetationRule) -> Mesh:
	if rule.mesh:
		return rule.mesh
	if rule.mesh_scene:
		var m := mesh_from_scene(rule.mesh_scene)
		if m:
			rule.mesh = m  # cache so we don't re-merge every chunk
		else:
			push_warning("PlanetVegetation: mesh_from_scene returned null for rule '%s'" % rule.rule_name)
		return m
	return null


## Merge all MeshInstance3D children of a PackedScene into a single ArrayMesh.
## Each source surface becomes a separate surface in the output, preserving materials.
static func mesh_from_scene(scene: PackedScene) -> ArrayMesh:
	if scene == null:
		return null
	var instance := scene.instantiate()
	var result_mesh := ArrayMesh.new()
	var found_any := false

	for child in instance.get_children():
		if child is MeshInstance3D and child.mesh:
			for surface_idx in child.mesh.get_surface_count():
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				st.append_from(child.mesh, surface_idx, child.transform)
				# PrimitiveMesh (CylinderMesh, etc.) may not expose normals
				# through append_from — regenerate to be safe.
				st.generate_normals()
				st.commit(result_mesh)
				found_any = true
				# Preserve the original material
				var mat: Material = child.mesh.surface_get_material(surface_idx)
				if mat == null:
					mat = child.material_override
				if mat:
					result_mesh.surface_set_material(
						result_mesh.get_surface_count() - 1, mat)

	instance.queue_free()
	if not found_any:
		return null
	return result_mesh
