@tool
class_name ForestTemperateForestSpawner
## Scatters lowpoly tree instances across terrain chunks that overlap the
## **forest-temperate_forest** biome.
##
## Follows the same architecture as [MeadowSteppeMeadowSpawner]:
##   1. Chunk-level AABB early exit
##   2. Grid-based candidate sampling with biome query
##   3. Density-gated acceptance + Fisher–Yates budget thinning
##   4. MultiMesh assembly with random yaw + scale variation
##
## Unlike the meadow spawner, trees are full 3D meshes (not billboard
## tufts), so no cross-plane merging is needed — the OBJ is used as-is.

# ── Tree mesh ────────────────────────────────────────────────────

## Path to the lowpoly tree OBJ model.
const TREE_MESH_PATH := "res://assets/_universe/environment/terrain/trees/tree001.glb"

# ── Cached statics ───────────────────────────────────────────────

## Per-LOD tree meshes extracted from the GLB (Tree_lod0, Tree_lod1, …).
static var _tree_meshes: Array[Mesh] = []
## Per-LOD offset from mesh origin to AABB bottom-center.
static var _mesh_base_offsets: Array[Vector3] = []
## Per-LOD visibility ranges from the GLB import settings.
## Each entry is Vector2(begin_distance, end_distance) in metres.
static var _lod_visibility_ranges: Array[Vector2] = []
## Whether the GLB has been loaded and meshes extracted.
static var _meshes_loaded := false


# ==================================================================
# Public API
# ==================================================================

## Build a [MultiMesh] of tree instances for one terrain chunk.
##
## Returns [code]null[/code] if the chunk contains no forest-temperate_forest.
## Instance transforms are relative to [param chunk_center] so the
## [MultiMeshInstance3D] can be placed there, keeping GPU float32
## values small.
static func scatter_trees(
		planet_data: PlanetData,
		biome_query,           # BiomeQuery (nullable when populate_zones provided)
		face: int,
		u_min: float, u_max: float,
		v_min: float, v_max: float,
		chunk_center: Vector3,
		chunk_lod: int = 0,
		hp_nside: int = 0,
		hp_ipix: int = -1,
		populate_zones: Array = [],
		linear_features: Array = []) -> MultiMesh:

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
			if _pz.get("biome_type", "") == ForestTemperateForestTerrain.BIOME_TYPE:
				_has_biome = true
				break
		if not _has_biome:
			return null
	elif hp_mode:
		if not biome_query.chunk_overlaps_biome_hp(hp_nside, hp_ipix,
				ForestTemperateForestTerrain.BIOME_TYPE):
			return null
	else:
		if not biome_query.chunk_overlaps_biome(face, u_min, u_max,
				v_min, v_max, ForestTemperateForestTerrain.BIOME_TYPE):
			return null

	# Clamp LOD to valid range for tree tiers.
	var lod_tier := clampi(chunk_lod, 0,
		maxi(ForestTemperateForestTerrain.TREE_LOD_BUDGET.size() - 1, 0))

	# ── Grid resolution (world-size / min spacing) ──────────────
	var chunk_size: float
	if hp_mode:
		chunk_size = HEALPix.pixel_side_length(hp_nside, planet_data.radius)
	else:
		var corner_a := PlanetData.cube_to_sphere(
			face, u_min, v_min) * planet_data.radius
		var corner_b := PlanetData.cube_to_sphere(
			face, u_max, v_max) * planet_data.radius
		chunk_size = corner_a.distance_to(corner_b)
	var spacing := maxf(ForestTemperateForestTerrain.TREE_MIN_SPACING_M, 0.5)
	var grid_from_spacing := clampi(int(chunk_size / spacing), 2, 300)
	var base_budget: int = ForestTemperateForestTerrain.get_tree_budget(lod_tier)
	var grid_from_budget := ceili(sqrt(float(base_budget) * 2.5))
	var grid_steps := mini(grid_from_spacing, maxi(grid_from_budget, 2))

	# Scale budget by representative zone density so low-density biomes
	# produce proportionally fewer trees even when the grid is fully covered.
	var center_dir: Vector3
	if hp_mode:
		center_dir = HEALPix.pix2vec_nest(hp_nside, hp_ipix)
	else:
		center_dir = PlanetData.cube_to_sphere(
			face, (u_min + u_max) * 0.5, (v_min + v_max) * 0.5)
	var _rep_zone: Dictionary = {}
	if _use_pz:
		var _pz_at_center := PlanetChunk._query_zones_at_direction(center_dir, populate_zones)
		for _pzz in _pz_at_center:
			if _pzz.get("biome_type", "") == ForestTemperateForestTerrain.BIOME_TYPE:
				_rep_zone = _pzz
				break
	elif biome_query:
		_rep_zone = biome_query.query_biome_type(
			center_dir, ForestTemperateForestTerrain.BIOME_TYPE)
	var _rep_density: float = _rep_zone.get("density",
		ForestTemperateForestTerrain.DEFAULT_VEGETATION_DENSITY) \
		if not _rep_zone.is_empty() \
		else ForestTemperateForestTerrain.DEFAULT_VEGETATION_DENSITY
	var budget: int = maxi(1, int(base_budget * _rep_density))

	var u_step := (u_max - u_min) / float(grid_steps)
	var v_step := (v_max - v_min) / float(grid_steps)

	# HEALPix pixel face-local coordinates for grid iteration.
	var _hp_face := 0
	var _hp_ix := 0
	var _hp_iy := 0
	if hp_mode:
		var _pxy: Dictionary = HEALPix.pix2face_xy(hp_nside, hp_ipix)
		_hp_face = _pxy["face"]
		_hp_ix = _pxy["ix"]
		_hp_iy = _pxy["iy"]

	# Deterministic RNG seeded from chunk bounds.
	var rng := RandomNumberGenerator.new()
	if hp_mode:
		rng.seed = hash(Vector2i(hp_nside, hp_ipix)) ^ 0x74726565  # "tree"
	else:
		rng.seed = hash(Vector4(u_min, v_min, u_max, v_max)) ^ 0x74726565  # "tree"

	# Road query — suppress trees on road surfaces.
	# The chunk's modifier tile already holds only THIS chunk's road pieces, so
	# the suppression test below is a point-to-polyline distance over a handful
	# of local points instead of a planet-wide zone scan per candidate.
	# BiomeQuery stays as the fallback for planets without a pack.
	var chunk_roads: Array = planet_data.get_roads_for_chunk(hp_nside, hp_ipix) \
		if hp_mode else []
	var road_m_per_deg: float = planet_data.radius * PI / 180.0
	var road_query = null
	var has_road_overlap := not chunk_roads.is_empty()
	if not has_road_overlap and planet_data.get_modifier_pack() == null:
		road_query = planet_data.get_road_query()  # may be null
		if road_query and road_query.is_loaded():
			if hp_mode:
				has_road_overlap = road_query.chunk_overlaps_any_zone_hp(
					hp_nside, hp_ipix)
			else:
				has_road_overlap = road_query.chunk_overlaps_any_zone(
					face, u_min, u_max, v_min, v_max)

	# River check — suppress trees inside river beds.
	var has_river_overlap := false
	if _use_pz:
		for _lf in linear_features:
			if _lf.get("type", "") == "maritime_river-river":
				var _lcl: Array = _lf.get("centerline", [])
				if _lcl.size() >= 2:
					has_river_overlap = true
					break
	elif hp_mode:
		has_river_overlap = biome_query.chunk_overlaps_biome_hp(
			hp_nside, hp_ipix, "maritime_river-river")
	else:
		has_river_overlap = biome_query.chunk_overlaps_biome(
			face, u_min, u_max, v_min, v_max, "maritime_river-river")

	# ── Phase 1: collect forest_temperate candidates ────────────
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
					if _pzz.get("biome_type", "") == ForestTemperateForestTerrain.BIOME_TYPE:
						zone = _pzz
						break
			elif biome_query:
				zone = biome_query.query_biome_type(
						dir, ForestTemperateForestTerrain.BIOME_TYPE)
			if zone.is_empty():
				continue

			# Skip trees on roads.
			if has_road_overlap:
				var rd_lonlat := BiomeQuery._dir_to_lonlat(dir)
				var on_road := false
				if not chunk_roads.is_empty():
					on_road = RoadTerrain.point_on_any_road(
						rd_lonlat.x, rd_lonlat.y, chunk_roads, road_m_per_deg)
				elif road_query:
					for rd_z in road_query.query_at_direction(dir):
						if RoadTerrain.is_road_zone(rd_z):
							RoadTerrain.prepare_zone(rd_z, planet_data.radius)
							if BiomeQuery.get_cross_section_t(rd_z, rd_lonlat).t < 1.0:
								on_road = true
								break
				if on_road:
					continue

			# Skip trees inside river beds.
			if has_river_overlap:
				var _in_river := false
				if _use_pz:
					var _r_lonlat := BiomeQuery._dir_to_lonlat(dir)
					for _rlf in linear_features:
						if _rlf.get("type", "") != "maritime_river-river":
							continue
						var _r_cl: PackedVector2Array = _rlf.get("centerline", PackedVector2Array())
						if _r_cl.size() < 2:
							continue
						MaritimeRiverRiverTerrain.prepare_zone(_rlf, planet_data.radius)
						var _r_cs := BiomeQuery.get_cross_section_t(_rlf, _r_lonlat)
						if _r_cs.t < 1.0:
							_in_river = true
							break
				elif biome_query:
					if not biome_query.query_biome_type(dir, "maritime_river-river").is_empty():
						_in_river = true
				if _in_river:
					continue

			# Physical density gate — density is a 0-1 fraction from QGIS.
			var density: float = zone.get("density",
				ForestTemperateForestTerrain.DEFAULT_VEGETATION_DENSITY)
			if density < 1.0 and rng.randf() >= density:
				continue
			candidates.append(cand)

	if candidates.is_empty():
		return null

	# ── Phase 2: thin to budget via partial Fisher–Yates ────────
	if candidates.size() > budget:
		for i in budget:
			var j := rng.randi_range(i, candidates.size() - 1)
			var tmp := candidates[i]
			candidates[i] = candidates[j]
			candidates[j] = tmp
		candidates.resize(budget)

	# ── Phase 3: build transforms ───────────────────────────────
	var transforms: Array[Transform3D] = []

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
		var arbitrary := Vector3.RIGHT \
			if absf(up.dot(Vector3.RIGHT)) < 0.99 else Vector3.FORWARD
		var right := up.cross(arbitrary).normalized()
		var forward := right.cross(up).normalized()
		var basis := Basis(right, up, forward)

		# Random yaw so trees don't all face the same direction.
		basis = basis * Basis(Vector3.UP, rng.randf() * TAU)

		# Random scale variation.
		var s := rng.randf_range(
			ForestTemperateForestTerrain.TREE_SCALE_MIN,
			ForestTemperateForestTerrain.TREE_SCALE_MAX)
		basis = basis.scaled(Vector3(s, s, s))

		# Shift so the AABB bottom-center (trunk base) sits at the
		# terrain surface instead of the mesh origin.
		var offset := basis * _get_base_offset(lod_tier)
		transforms.append(Transform3D(basis, pos - offset))

	if transforms.is_empty():
		return null

	# ── Phase 4: assemble MultiMesh ─────────────────────────────
	var mesh := _get_tree_mesh(lod_tier)
	if mesh == null:
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()

	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])

	return mm


## HEALPix convenience wrapper — delegates to [method scatter_trees].
static func scatter_trees_hp(
		planet_data: PlanetData,
		biome_query,
		nside: int, ipix: int,
		chunk_center: Vector3,
		chunk_lod: int = 0,
		populate_zones: Array = [],
		linear_features: Array = []) -> MultiMesh:
	return scatter_trees(planet_data, biome_query, 0,
			0.0, 0.0, 0.0, 0.0, chunk_center, chunk_lod,
			nside, ipix, populate_zones, linear_features)


# ==================================================================
# Mesh loading (lazy-cached)
# ==================================================================

## Load all LOD meshes from the GLB scene on first call.
## The GLB contains nodes named Tree_lod0, Tree_lod1, Tree_lod2 etc.
## Each is extracted, material-fixed, and cached in [member _tree_meshes].
static func _load_tree_meshes() -> void:
	if _meshes_loaded:
		return
	_meshes_loaded = true

	var scene := load(TREE_MESH_PATH) as PackedScene
	if scene == null:
		push_warning("[ForestTemperateForestSpawner] Could not load tree scene: %s"
			% TREE_MESH_PATH)
		return
	var instance := scene.instantiate()

	# Collect all MeshInstance3D children whose names contain "lod".
	var lod_nodes: Array[MeshInstance3D] = []
	for child in instance.find_children("*", "MeshInstance3D", true):
		var mi := child as MeshInstance3D
		if mi and mi.mesh and mi.name.to_lower().contains("lod"):
			lod_nodes.append(mi)

	# Sort by name so lod0 < lod1 < lod2.
	lod_nodes.sort_custom(func(a, b): return a.name.naturalcasecmp_to(b.name) < 0)

	# Fallback: if no "lod" nodes found, grab the first MeshInstance3D.
	if lod_nodes.is_empty():
		var first_mi: MeshInstance3D
		if instance is MeshInstance3D:
			first_mi = instance
		else:
			for child in instance.find_children("*", "MeshInstance3D", true):
				first_mi = child as MeshInstance3D
				break
		if first_mi and first_mi.mesh:
			lod_nodes.append(first_mi)

	_tree_meshes.clear()
	_mesh_base_offsets.clear()
	_lod_visibility_ranges.clear()

	for mi in lod_nodes:
		var mesh := mi.mesh.duplicate() as Mesh

		# ── Compute base offset (bottom-center of AABB) ──────
		var aabb := mesh.get_aabb()
		var base_off := Vector3(
			aabb.get_center().x,
			aabb.position.y,       # bottom Y = base of trunk
			aabb.get_center().z)

		# ── Fix leaf transparency ───────────────────────────
		for si in mesh.get_surface_count():
			var mat := mesh.surface_get_material(si)
			if mat == null:
				continue
			if mat is StandardMaterial3D:
				var smat := mat.duplicate() as StandardMaterial3D
				if smat.albedo_texture != null:
					smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
					smat.alpha_scissor_threshold = 0.5
					smat.cull_mode = BaseMaterial3D.CULL_DISABLED
				mesh.surface_set_material(si, smat)

		_tree_meshes.append(mesh)
		_mesh_base_offsets.append(base_off)
		_lod_visibility_ranges.append(Vector2(
			mi.visibility_range_begin, mi.visibility_range_end))
		print("[ForestTemperateForestSpawner] LOD %d (%s): AABB=%s  base_offset=%s  vis_range=%.1f-%.1fm" % [
			_tree_meshes.size() - 1, mi.name, aabb, base_off,
			mi.visibility_range_begin, mi.visibility_range_end])

	instance.free()

	if _tree_meshes.is_empty():
		push_warning("[ForestTemperateForestSpawner] No meshes found in: %s"
			% TREE_MESH_PATH)


## Return the cached tree [Mesh] for the given LOD tier.
## Loads all LOD meshes from the GLB on first access.
static func _get_tree_mesh(lod_tier: int = 0) -> Mesh:
	_load_tree_meshes()
	if _tree_meshes.is_empty():
		return null
	var idx := clampi(lod_tier, 0, _tree_meshes.size() - 1)
	return _tree_meshes[idx]


## Return the base-offset vector for the given LOD tier.
static func _get_base_offset(lod_tier: int = 0) -> Vector3:
	if _mesh_base_offsets.is_empty():
		return Vector3.ZERO
	var idx := clampi(lod_tier, 0, _mesh_base_offsets.size() - 1)
	return _mesh_base_offsets[idx]


## Number of LOD levels available in the GLB (triggers lazy load).
static func get_lod_count() -> int:
	_load_tree_meshes()
	return _tree_meshes.size()


## Maximum LOD index (0-based).  Returns 0 if only one mesh exists.
static func get_max_lod() -> int:
	return maxi(get_lod_count() - 1, 0)


## Visibility range for the given LOD tier as Vector2(begin, end) in metres.
## Read from the GLB import settings (visibility_range_begin / _end).
static func get_visibility_range(lod_tier: int = 0) -> Vector2:
	_load_tree_meshes()
	if _lod_visibility_ranges.is_empty():
		return Vector2.ZERO
	var idx := clampi(lod_tier, 0, _lod_visibility_ranges.size() - 1)
	return _lod_visibility_ranges[idx]
