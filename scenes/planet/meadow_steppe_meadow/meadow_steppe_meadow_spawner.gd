@tool
class_name MeadowSteppeMeadowSpawner
## Scatters grass stalk instances across terrain chunks that overlap the
## **meadow_steppe-meadow** biome.
##
## Unlike point-biome spawners (fumarole, volcanic_geothermal-active_volcano) which place a
## single feature at a zone centroid, this spawner fills the chunk with
## many small grass stalk instances via [MultiMesh].
##
## The base mesh is loaded from an OBJ file (a single flat grass stalk).
## For close-up LODs, multiple rotated copies of the stalk are merged
## into a single ArrayMesh to form a cross-plane tuft visible from
## every angle.

# ── Grass stalk mesh ─────────────────────────────────────────

## Path to the grass stalk OBJ model.
const GRASS_STALK_PATH := "res://assets/_universe/environment/terrain/grass-stalk.obj"

## Number of individual blades merged into a single tuft mesh (LOD 0).
## 8 blades at random rotations + small XZ offsets give a natural clump
## visible from every angle.  Lower LODs use fewer blades (see
## [member MeadowSteppeMeadowTerrain.GRASS_LOD_BLADES]).
const BLADES_PER_TUFT := 8

## Radius (metres) within which blades are randomly offset from tuft centre.
## At ~3 tufts/m² on a 200 m chunk, average inter-tuft spacing is ~0.58 m.
## 0.35 m radius (0.70 m diameter) ensures neighbouring tufts overlap,
## closing the visible gaps between clumps.
const TUFT_RADIUS := 0.35

# ── Cached statics ───────────────────────────────────────────

static var _grass_mat: ShaderMaterial
## The base single-plane mesh loaded from OBJ (cached).
static var _base_stalk_mesh: Mesh
## One cached tuft mesh per LOD tier (indexed 0..GRASS_MAX_LOD).
static var _grass_meshes: Array[ArrayMesh] = []


# ==================================================================
# Public API
# ==================================================================

## Build a [MultiMesh] of grass blade tufts for one terrain chunk.
##
## Returns [code]null[/code] if the chunk contains no meadow.
## Instance transforms are relative to [param chunk_center] so the
## [MultiMeshInstance3D] can be placed there, keeping GPU float32
## values small.
static func scatter_grass(
		planet_data: PlanetData,
		biome_query,           # BiomeQuery (nullable when populate_zones provided)
		face: int,
		u_min: float, u_max: float,
		v_min: float, v_max: float,
		chunk_center: Vector3,
		chunk_lod: int = 0,
		hp_nside: int = 0,
		hp_ipix: int = -1,
		populate_zones: Array = []) -> MultiMesh:

	var hp_mode := hp_nside > 0
	var _use_pz := not populate_zones.is_empty()

	if planet_data == null:
		return null
	if not _use_pz and biome_query == null:
		return null

	# ── Chunk-level early exit ──────────────────────────────────
	if _use_pz:
		var _has_biome := false
		for _pz in populate_zones:
			if _pz.get("biome_type", "") == MeadowSteppeMeadowTerrain.BIOME_TYPE:
				_has_biome = true
				break
		if not _has_biome:
			return null
	elif hp_mode:
		if not biome_query.chunk_overlaps_biome_hp(hp_nside, hp_ipix,
				MeadowSteppeMeadowTerrain.BIOME_TYPE):
			return null
	else:
		if not biome_query.chunk_overlaps_biome(face, u_min, u_max,
				v_min, v_max, MeadowSteppeMeadowTerrain.BIOME_TYPE):
			return null

	# Road query — suppress grass tufts on road surfaces.
	var road_query = planet_data.get_road_query()  # may be null
	var has_road_overlap := false
	if road_query and road_query.is_loaded():
		if hp_mode:
			has_road_overlap = road_query.chunk_overlaps_any_zone_hp(
				hp_nside, hp_ipix)
		else:
			has_road_overlap = road_query.chunk_overlaps_any_zone(
				face, u_min, u_max, v_min, v_max)

	# Clamp LOD to valid range for grass tiers.
	var lod_tier := clampi(chunk_lod, 0, MeadowSteppeMeadowTerrain.GRASS_LOD_BUDGET.size() - 1)

	# ── Grid resolution (world-size / min spacing) ──────────────
	var chunk_size: float
	if hp_mode:
		chunk_size = HEALPix.pixel_side_length(hp_nside, planet_data.radius)
	else:
		var corner_a := PlanetData.cube_to_sphere(face, u_min, v_min) * planet_data.radius
		var corner_b := PlanetData.cube_to_sphere(face, u_max, v_max) * planet_data.radius
		chunk_size = corner_a.distance_to(corner_b)
	var spacing := maxf(MeadowSteppeMeadowTerrain.GRASS_MIN_SPACING_M, 0.1)
	var grid_from_spacing := clampi(int(chunk_size / spacing), 2, 750)
	var grid_from_budget  := ceili(sqrt(float(MeadowSteppeMeadowTerrain.GRASS_MAX_PER_CHUNK) * 2.5))
	var grid_steps := mini(grid_from_spacing, maxi(grid_from_budget, 2))

	var u_step := (u_max - u_min) / float(grid_steps)
	var v_step := (v_max - v_min) / float(grid_steps)

	# HEALPix pixel face-local coordinates for grid iteration.
	var _hp_face := 0
	var _hp_ix := 0
	var _hp_iy := 0
	if hp_mode:
		var _pxy = HEALPix.pix2face_xy(hp_nside, hp_ipix)
		_hp_face = _pxy["face"]
		_hp_ix = _pxy["ix"]
		_hp_iy = _pxy["iy"]

	# Area of a single grid cell in m² (for physical density gate).
	var cell_side_m := chunk_size / float(grid_steps)
	var cell_area_m2 := cell_side_m * cell_side_m

	# Deterministic RNG seeded from chunk bounds.
	var rng := RandomNumberGenerator.new()
	if hp_mode:
		rng.seed = hash(Vector2i(hp_nside, hp_ipix)) ^ 0x6772617373  # "grass"
	else:
		rng.seed = hash(Vector4(u_min, v_min, u_max, v_max)) ^ 0x6772617373  # "grass"

	# ── Phase 1: collect meadow candidates ─────────────────────
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
				var u := u_min + (float(xi) + rng.randf()) * u_step
				var v := v_min + (float(yi) + rng.randf()) * v_step
				u = clampf(u, u_min, u_max)
				v = clampf(v, v_min, v_max)
				dir = PlanetData.cube_to_sphere(face, u, v)
				cand = Vector2(u, v)
			var zone: Dictionary = {}
			if _use_pz:
				var _pz_at := PlanetChunk._query_zones_at_direction(dir, populate_zones)
				for _pzz in _pz_at:
					if _pzz.get("biome_type", "") == MeadowSteppeMeadowTerrain.BIOME_TYPE:
						zone = _pzz
						break
			elif biome_query:
				zone = biome_query.query_biome_type(
						dir, MeadowSteppeMeadowTerrain.BIOME_TYPE)
			if zone.is_empty():
				continue

			# Skip grass on roads — no tufts where a trail/path/road crosses.
			if has_road_overlap:
				var rd_zones: Array[Dictionary] = road_query.query_at_direction(dir)
				var on_road := false
				for rd_z in rd_zones:
					if RoadTerrain.is_road_zone(rd_z):
						RoadTerrain.prepare_zone(rd_z, planet_data.radius)
						var rd_lonlat := BiomeQuery._dir_to_lonlat(dir)
						var _rd_cs := BiomeQuery.get_cross_section_t(rd_z, rd_lonlat)
						if _rd_cs.t < 1.0:
							on_road = true
							break
				if on_road:
					continue

			# Physical density gate: density=1.0 → 10 blades/cm².
			# Compute how many tufts this cell *should* contain and use
			# that as the acceptance probability (clamped to 1.0).
			var density: float = zone.get("density", 1.0)
			var expected_tufts := density * MeadowSteppeMeadowTerrain.TUFTS_PER_M2_FULL * cell_area_m2
			var accept_prob := clampf(expected_tufts, 0.0, 1.0)
			if accept_prob < 1.0 and rng.randf() >= accept_prob:
				continue
			candidates.append(cand)

	if candidates.is_empty():
		return null

	# ── Phase 2: thin to budget via partial Fisher–Yates ────────
	var budget: int = MeadowSteppeMeadowTerrain.GRASS_LOD_BUDGET[lod_tier]
	if candidates.size() > budget:
		for i in budget:
			var j := rng.randi_range(i, candidates.size() - 1)
			var tmp := candidates[i]
			candidates[i] = candidates[j]
			candidates[j] = tmp
		candidates.resize(budget)

	# ── Phase 3: build transforms & per-instance colours ────────
	var transforms: Array[Transform3D] = []
	var colors: PackedColorArray = []

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

		# Orient Y-up to planet surface normal (≈ dir on a sphere).
		var up := dir
		var arbitrary := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.99 else Vector3.FORWARD
		var right := up.cross(arbitrary).normalized()
		var forward := right.cross(up).normalized()
		var basis := Basis(right, up, forward)

		# Random yaw so blades don't align.
		basis = basis * Basis(Vector3.UP, rng.randf() * TAU)

		# Random scale variation (0.7× – 1.5×).
		var s := rng.randf_range(0.7, 1.5)
		basis = basis.scaled(Vector3(s, s, s))

		transforms.append(Transform3D(basis, pos))
		# Per-instance colour seeds read by the grass shader:
		#   R = flower threshold seed
		#   G = dry / green mix seed
		#   B = hue shift seed
		colors.append(Color(rng.randf(), rng.randf() * 0.5, rng.randf()))

	if transforms.is_empty():
		return null

	# ── Phase 4: assemble MultiMesh ─────────────────────────────
	var mesh := _get_grass_mesh(lod_tier)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = transforms.size()

	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_color(i, colors[i])

	return mm


## HEALPix convenience wrapper — delegates to [method scatter_grass].
static func scatter_grass_hp(
		planet_data: PlanetData,
		biome_query,
		nside: int, ipix: int,
		chunk_center: Vector3,
		chunk_lod: int = 0,
		populate_zones: Array = []) -> MultiMesh:
	return scatter_grass(planet_data, biome_query, 0,
			0.0, 0.0, 0.0, 0.0, chunk_center, chunk_lod,
			nside, ipix, populate_zones)


# ==================================================================
# Mesh & material construction (lazy-cached)
# ==================================================================

## Return (or build) the cached grass tuft [ArrayMesh] for the given
## LOD tier.  Each tier has a different blade count per tuft:
## LOD 0 → 12 blades, LOD 1 → 6, LOD 2 → 2.
static func _get_grass_mesh(lod_tier: int = 0) -> ArrayMesh:
	# Grow the cache array to cover requested tier.
	while _grass_meshes.size() <= lod_tier:
		_grass_meshes.append(null)
	if _grass_meshes[lod_tier]:
		return _grass_meshes[lod_tier]
	var blades_arr: Array = MeadowSteppeMeadowTerrain.GRASS_LOD_BLADES
	var blade_count: int = blades_arr[clampi(lod_tier, 0, blades_arr.size() - 1)]
	_grass_meshes[lod_tier] = _build_tuft_mesh(blade_count)
	return _grass_meshes[lod_tier]


## Return (or load) the base grass stalk [Mesh] from the OBJ file.
static func _get_base_stalk_mesh() -> Mesh:
	if _base_stalk_mesh:
		return _base_stalk_mesh
	_base_stalk_mesh = load(GRASS_STALK_PATH) as Mesh
	if _base_stalk_mesh == null:
		push_warning("[MeadowSteppeMeadowSpawner] Could not load grass stalk mesh: %s" % GRASS_STALK_PATH)
	return _base_stalk_mesh


## Return (or build) the shared grass blade [ShaderMaterial].
static func _get_grass_material() -> Material:
	if _grass_mat:
		return _grass_mat
	var shader := load("res://assets/materials/planet/meadow_grass.gdshader") as Shader
	if shader:
		_grass_mat = ShaderMaterial.new()
		_grass_mat.shader = shader
	else:
		# Fallback: simple green material if shader is missing.
		push_warning("[MeadowSteppeMeadowSpawner] meadow_grass.gdshader not found — using fallback")
		var fallback := StandardMaterial3D.new()
		fallback.albedo_color = Color(0.2, 0.4, 0.1)
		fallback.cull_mode = BaseMaterial3D.CULL_DISABLED
		_grass_mat = ShaderMaterial.new()
		_grass_mat.shader = fallback.get_shader() if fallback.get_shader() else null
		return fallback
	return _grass_mat


## Build a grass tuft mesh with [param blade_count] individual stalk blades
## merged into a single [ArrayMesh].
## Each blade gets a random Y-axis rotation, a small random XZ offset
## within [constant TUFT_RADIUS], and slight height variation so the
## clump looks organic from every viewing angle.
## Uses a fixed seed so all tuft meshes are identical (per-instance
## variation comes from MultiMesh transforms).
static func _build_tuft_mesh(blade_count: int = BLADES_PER_TUFT) -> ArrayMesh:
	var base := _get_base_stalk_mesh()
	if base == null or base.get_surface_count() == 0:
		push_warning("[MeadowSteppeMeadowSpawner] Base stalk mesh unavailable — using procedural fallback")
		return _build_fallback_mesh(blade_count)

	# Extract the base surface arrays once.
	var src_arrays: Array = base.surface_get_arrays(0)
	var src_verts: PackedVector3Array = src_arrays[Mesh.ARRAY_VERTEX]
	var src_normals: PackedVector3Array = src_arrays[Mesh.ARRAY_NORMAL] if src_arrays[Mesh.ARRAY_NORMAL] else PackedVector3Array()
	var src_uvs: PackedVector2Array = src_arrays[Mesh.ARRAY_TEX_UV] if src_arrays[Mesh.ARRAY_TEX_UV] else PackedVector2Array()
	var src_indices: PackedInt32Array = src_arrays[Mesh.ARRAY_INDEX] if src_arrays[Mesh.ARRAY_INDEX] else PackedInt32Array()

	var all_verts   := PackedVector3Array()
	var all_normals := PackedVector3Array()
	var all_uvs     := PackedVector2Array()
	var all_indices := PackedInt32Array()

	# Deterministic RNG so every tuft mesh is identical.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x747566  # "tuf"

	for bi in blade_count:
		var vert_offset := all_verts.size()

		# Random Y-axis rotation (full circle).
		var yaw := rng.randf() * TAU
		var rot := Basis(Vector3.UP, yaw)

		# Random XZ offset – sqrt gives uniform-area distribution so blades
		# spread evenly across the disc instead of clustering at the centre.
		# A minimum radius of 30% prevents blades from stacking on top of
		# each other at the tuft origin.
		var off_angle := rng.randf() * TAU
		var off_dist := lerpf(TUFT_RADIUS * 0.3, TUFT_RADIUS, sqrt(rng.randf()))
		var offset := Vector3(
			cos(off_angle) * off_dist,
			0.0,
			sin(off_angle) * off_dist)

		# Slight height variation per blade (0.7× – 1.3×).
		var h_scale := rng.randf_range(0.7, 1.3)

		# Rotate + scale + offset vertices.
		for v in src_verts:
			var rv := rot * v
			rv.y *= h_scale
			all_verts.append(rv + offset)
		for n in src_normals:
			all_normals.append(rot * n)
		# UVs are copied as-is per blade.
		all_uvs.append_array(src_uvs)
		# Offset indices by vertex base.
		for idx in src_indices:
			all_indices.append(idx + vert_offset)

	# If the OBJ had no index array, build one from sequential triangles.
	if src_indices.is_empty():
		all_indices.resize(0)
		for ci in blade_count:
			var base_off := ci * src_verts.size()
			for vi in range(0, src_verts.size() - 2, 3):
				all_indices.append(base_off + vi)
				all_indices.append(base_off + vi + 1)
				all_indices.append(base_off + vi + 2)

	# Assemble ArrayMesh surface.
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = all_verts
	if not all_normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = all_normals
	if not all_uvs.is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = all_uvs
	arrays[Mesh.ARRAY_INDEX] = all_indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _get_grass_material())
	return mesh


## Procedural fallback card mesh if the OBJ file is missing.
## Creates [param blade_count] thin quads with random rotation + offset,
## mimicking the clump placement of the real OBJ tuft.
static func _build_fallback_mesh(blade_count: int = BLADES_PER_TUFT) -> ArrayMesh:
	var verts   := PackedVector3Array()
	var uvs     := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()

	var hw := 0.06   # roughly match the OBJ half-width
	var h  := 1.04   # roughly match the OBJ height

	# Same deterministic RNG as the real tuft builder.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x747566  # "tuf"

	for bi in blade_count:
		var yaw := rng.randf() * TAU
		var ca := cos(yaw)
		var sa := sin(yaw)

		var off_angle := rng.randf() * TAU
		var off_dist := rng.randf() * TUFT_RADIUS
		var offset := Vector3(cos(off_angle) * off_dist, 0.0, sin(off_angle) * off_dist)

		var h_scale := rng.randf_range(0.7, 1.3)
		var bh := h * h_scale

		var off := verts.size()

		var bl := Vector3(-hw * ca, 0.0, -hw * sa) + offset
		var br := Vector3( hw * ca, 0.0,  hw * sa) + offset
		var top_r := Vector3( hw * ca, bh,   hw * sa) + offset
		var tl := Vector3(-hw * ca, bh,  -hw * sa) + offset

		verts.append(bl); verts.append(br); verts.append(top_r); verts.append(tl)
		uvs.append(Vector2(0.0, 0.0)); uvs.append(Vector2(1.0, 0.0))
		uvs.append(Vector2(1.0, 1.0)); uvs.append(Vector2(0.0, 1.0))

		var face_n := (br - bl).cross(tl - bl).normalized()
		normals.append(face_n); normals.append(face_n)
		normals.append(face_n); normals.append(face_n)

		indices.append(off + 0); indices.append(off + 1); indices.append(off + 2)
		indices.append(off + 0); indices.append(off + 2); indices.append(off + 3)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _get_grass_material())
	return mesh
