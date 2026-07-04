@tool
class_name PlanetChunk
## Static helpers for generating terrain-chunk meshes & collision shapes.
##
## Each chunk covers a rectangular patch on one cube-sphere face.
## Vertices are displaced along the sphere normal by the heightmap value.
## Biome colours are baked into vertex colours so the base material uses
## [code]vertex_color_use_as_albedo = true[/code].

## Biome terrain constants are now in self-contained modules:
##   Linear: MaritimeRiverRiverTerrain, RockyLandformCanyonTerrain, IcyIceCrevasseTerrain,
##           ArideDesertDryRiverBedTerrain, RockyLandformPressureCanyonTerrain, VolcanicGeothermalLavaRiverTerrain
##   Point:  CaveTerrain, SpatialCraterTerrain, VolcanicGeothermalFumaroleTerrain, VolcanicGeothermalIceGeyserTerrain,
##           VolcanicGeothermalMineralThermalSourceTerrain
##   Overlay: RoadTerrain (biome-adaptive road textures)


## Bitmask constants for LOD-stitching edges (reserved for future use).
const STITCH_LEFT   := 1
const STITCH_RIGHT  := 2
const STITCH_BOTTOM := 4
const STITCH_TOP    := 8

# One-shot guard for the corundum-override debug print (temporary).
static var _corundum_logged := false


## Generate a visual [ArrayMesh] for one terrain chunk.
## [param data] — planet configuration (heightmap, radius, etc.)
## [param face] — cube face index 0–5
## [param u_min] / [param u_max] — horizontal bounds on the face (−1 … 1)
## [param v_min] / [param v_max] — vertical bounds on the face (−1 … 1)
## [param resolution] — number of quads per edge (vertex count = res + 1)
static func generate_mesh(
		data: PlanetData,
		face: int,
		u_min: float, u_max: float,
		v_min: float, v_max: float,
		resolution: int,
		chunk_center: Vector3 = Vector3.ZERO,
		hp_nside: int = 0,
		hp_ipix: int = -1) -> ArrayMesh:

	var res := resolution
	var vert_count := (res + 1) * (res + 1)
	var vertices := PackedVector3Array()
	var normals  := PackedVector3Array()
	var uvs      := PackedVector2Array()
	var uv2s     := PackedVector2Array()  # .x = detail layer index, .y = detail tiling scale
	var colors   := PackedColorArray()
	var indices  := PackedInt32Array()
	# CUSTOM0: inverse skirt offset (3 floats per vertex).  Zero for terrain
	# vertices; non-zero for skirt vertices so the shader can recover the
	# surface position for triplanar UV:  surface_pos = VERTEX + CUSTOM0.
	var skirt_offsets := PackedFloat32Array()

	vertices.resize(vert_count)
	normals.resize(vert_count)
	uvs.resize(vert_count)
	uv2s.resize(vert_count)
	colors.resize(vert_count)
	skirt_offsets.resize(vert_count * 3)  # initialized to 0.0 for surface verts

	var hp_mode := hp_nside > 0
	var u_step := (u_max - u_min) / float(res) if not hp_mode else 0.0
	var v_step := (v_max - v_min) / float(res) if not hp_mode else 0.0

	# HEALPix direction grid (replaces cube-sphere u/v iteration).
	var grid_dirs: Array[PackedVector3Array] = []
	# Export-level ipix for height sampling.  Using the deterministic
	# parent-chain avoids vec2pix_nest rounding at the polar/equatorial
	# cap boundary where it may return a pixel on the wrong face.
	# When the chunk is COARSER than export_nside (low-LOD chunks like
	# hp_n1/2/4/8 vs export_nside=64), it spans many export tiles, so
	# there is no single export ipix; leave it -1 and let
	# sample_height_for_direction resolve per-vertex via vec2pix_nest.
	var _export_ipix: int = -1
	if hp_mode:
		grid_dirs = HEALPix.get_pixel_grid(hp_nside, hp_ipix, res)
		if hp_nside >= data.export_nside:
			_export_ipix = hp_ipix
			var _ns := hp_nside
			while _ns > data.export_nside:
				_export_ipix >>= 2
				_ns /= 2

	# ── Float32 precision fix ──────────────────────────────────────
	# Vertex positions are stored as float32 in PackedVector3Array.
	# To minimise seams between adjacent chunks we force chunk_center
	# through a float32 round-trip so that the GPU-side mi.position
	# (camera-relative f32) is consistent.
	#
	# We compute  local = world_f64 - cc_f32  in float64 (GDScript
	# native precision in Double-Precision builds), then snap the
	# *result* to float32 for the mesh buffer.  This preserves height
	# precision to ~60 µm (ULP at ±500 m local range) instead of the
	# ~0.12–0.25 m terracing caused by snapping the world position to
	# float32 before subtracting.
	# Skirt geometry hides any sub-mm boundary seams this introduces.
	var _cc_f32 := PackedFloat32Array([chunk_center.x, chunk_center.y, chunk_center.z])
	var cc_f32 := Vector3(_cc_f32[0], _cc_f32[1], _cc_f32[2])
	# Reusable buffer for snapping local-space offsets to float32.
	var _wp_f32 := PackedFloat32Array([0.0, 0.0, 0.0])

	# Pre-fetch recipe biome data for this chunk (replaces BiomeQuery).
	var _rbd := _get_recipe_biome_data(data, hp_nside, hp_ipix)
	var _pz_zones: Array = _rbd[0]   # populate_zones
	var _lf_arr: Array = _rbd[1]     # linear_features
	var _rf_arr: Array = _rbd[2]     # radial_features
	var _cr_arr: Array = _rbd[3]     # sub-pixel craters

	# Quick check: does this chunk potentially overlap any liquid/shallow zone?
	# Derived from recipe data — no GeoJSON needed.
	var has_liquid_overlap := false
	var has_shallow_water_overlap := false
	var has_river_overlap := false
	var _river_zones: Array[Dictionary] = []  # linear features matching river
	var has_linear_overlap := false
	var has_point_overlap := false
	var has_crater_overlap := not _cr_arr.is_empty()
	var has_volcanic_active_overlap := false
	var has_lunar_ground_overlap := false
	var has_lava_river_overlap := false
	var has_meadow_overlap := false
	var has_forest_ground_overlap := false
	var has_cliff_overlap := false
	var has_dry_river_bed_overlap := false
	var _dry_river_bed_zones: Array[Dictionary] = []  # linear features matching dry riverbed

	# Road overlay: uses a separate BiomeQuery loaded from roads_geojson.
	var rq = data.get_road_query()  # may be null
	var has_road_overlap := false

	# HEALPix lon/lat bounding box (reused for road overlay).
	var _cbb: Array[Vector2] = []
	if hp_mode:
		var _hp_corners: Array = HEALPix.get_pixel_corners(hp_nside, hp_ipix)
		var _hp_cdir := HEALPix.pix2vec_nest(hp_nside, hp_ipix)
		var _cbb_mn := Vector2(INF, INF)
		var _cbb_mx := Vector2(-INF, -INF)
		var _bbox_dirs: Array[Vector3] = []
		for _ci in _hp_corners.size():
			_bbox_dirs.append(_hp_corners[_ci])
			_bbox_dirs.append((_hp_corners[_ci] + _hp_corners[(_ci + 1) % _hp_corners.size()]).normalized())
		_bbox_dirs.append(_hp_cdir)
		for _bs in _bbox_dirs:
			var _bll := HEALPix.vec2lonlat(_bs)
			_cbb_mn.x = minf(_cbb_mn.x, _bll.x)
			_cbb_mn.y = minf(_cbb_mn.y, _bll.y)
			_cbb_mx.x = maxf(_cbb_mx.x, _bll.x)
			_cbb_mx.y = maxf(_cbb_mx.y, _bll.y)
		_cbb = [_cbb_mn, _cbb_mx]
		if rq and rq.is_loaded():
			for _rz in rq.get_zones_for_region(_cbb_mn, _cbb_mx):
				if BiomeQuery._aabb_overlap(_cbb_mn, _cbb_mx, _rz.bbox_min, _rz.bbox_max):
					has_road_overlap = true
					break
	else:
		if rq and rq.is_loaded():
			has_road_overlap = rq.chunk_overlaps_any_zone(
				face, u_min, u_max, v_min, v_max)

	# ── Recipe-based overlap detection ─────────────────────────────
	# Populate zones (polygon/point biomes).
	for _pz in _pz_zones:
		var _bt: String = _pz.get("biome_type", "")
		var _bd = data.get_biome_by_type(_bt)
		if _bd == null:
			continue
		if _bd.is_liquid and data.has_ocean:
			has_liquid_overlap = true
		if _bd.get("has_shallow_water"):
			has_shallow_water_overlap = true
		if CaveTerrain.is_cave_biome(_bd) \
				or VolcanicGeothermalFumaroleTerrain.is_fumarole_biome(_bd) \
				or VolcanicGeothermalIceGeyserTerrain.matches_zone(_bd) \
				or VolcanicGeothermalMineralThermalSourceTerrain.matches_zone(_bd) \
				or VolcanicGeothermalActiveVolcanoTerrain.is_active_volcano_biome(_bd):
			has_point_overlap = true
		if VolcanicGeothermalActiveVolcanoTerrain.is_active_volcano_biome(_bd):
			has_volcanic_active_overlap = true
		if SpatialLunarGroundTerrain.matches_zone(_bd):
			has_lunar_ground_overlap = true
		if MeadowSteppeMeadowTerrain.matches_zone(_bd):
			has_meadow_overlap = true
		if ForestTemperateForestTerrain.matches_zone(_bd):
			has_forest_ground_overlap = true
		if RockyLandformCliffTerrain.matches_zone(_bd):
			has_cliff_overlap = true
		if SpatialCraterTerrain.is_crater_biome(_bd):
			has_crater_overlap = true

	# Linear features (rivers, canyons, crevasses, lava rivers, etc.).
	for _lf in _lf_arr:
		var _lt: String = _lf.get("type", "")
		var _lcl: Array = _lf.get("centerline", [])
		if _lcl.size() < 2:
			continue
		if _lt == "maritime_river-river":
			has_river_overlap = true
			_river_zones.append(_lf)
		elif _lt == "volcanic_geothermal-lava_river":
			has_lava_river_overlap = true
		elif _lt == "aride_desert-dry_river_bed":
			has_linear_overlap = true
			has_dry_river_bed_overlap = true
			_dry_river_bed_zones.append(_lf)
		elif _lt == "rocky_landform-canyon" or _lt == "icy-ice_crevasse" \
				or _lt == "rocky_landform-pressure_canyon":
			has_linear_overlap = true

	# Radial features.
	for _rf in _rf_arr:
		var _rt: String = _rf.get("type", "")
		if _rt == "volcanic_geothermal-active_volcano":
			has_volcanic_active_overlap = true
			has_point_overlap = true

	# Pre-prepare river zones (linear features have same keys as prepare_zone expects).
	if has_river_overlap:
		for _rz in _river_zones:
			var _rcl: Array = _rz.get("centerline", [])
			if _rcl.size() >= 2:
				MaritimeRiverRiverTerrain.prepare_zone(_rz, data.radius)
	if has_dry_river_bed_overlap:
		for _drbz in _dry_river_bed_zones:
			var _drbcl: Array = _drbz.get("centerline", [])
			if _drbcl.size() >= 2:
				ArideDesertDryRiverBedTerrain.prepare_zone(_drbz, data.radius)

	# Per-vertex: liquid flag + original terrain height (before depression).
	var is_liquid_vertex: PackedByteArray = PackedByteArray()
	var original_height: PackedFloat32Array = PackedFloat32Array()
	if has_liquid_overlap:
		is_liquid_vertex.resize(vert_count)
		original_height.resize(vert_count)

	# Per-vertex: shallow water flag (swamp, bog, marsh).
	var is_shallow_water_vertex: PackedByteArray = PackedByteArray()
	if has_shallow_water_overlap:
		is_shallow_water_vertex.resize(vert_count)

	# Per-vertex: volcanic_active flag for lava overlay.
	var is_volcanic_active_vertex: PackedByteArray = PackedByteArray()
	if has_volcanic_active_overlap:
		is_volcanic_active_vertex.resize(vert_count)

	# Per-vertex: lunar_ground flag for lunar ground material overlay.
	var is_lunar_ground_vertex: PackedByteArray = PackedByteArray()
	if has_lunar_ground_overlap:
		is_lunar_ground_vertex.resize(vert_count)

	# Per-vertex: meadow flag for grass ground material overlay.
	var is_meadow_vertex: PackedByteArray = PackedByteArray()
	if has_meadow_overlap:
		is_meadow_vertex.resize(vert_count)

	# Per-vertex: forest_ground flag for leaf-litter material overlay.
	var is_forest_ground_vertex: PackedByteArray = PackedByteArray()
	if has_forest_ground_overlap:
		is_forest_ground_vertex.resize(vert_count)

	# Per-vertex: cliff flag for cliff face material overlay.
	var is_cliff_vertex: PackedByteArray = PackedByteArray()
	if has_cliff_overlap:
		is_cliff_vertex.resize(vert_count)

	# Per-vertex: lava_river flag + original height before depression.
	# The lava surface sits at the original terrain height (like water),
	# so we need to remember the pre-depression height per vertex.
	# Flow-aligned UVs are pre-computed so the texture follows the river.
	var is_lava_river_vertex: PackedByteArray = PackedByteArray()
	var lava_river_original_height: PackedFloat32Array = PackedFloat32Array()
	var lava_river_flow_uv: PackedVector2Array = PackedVector2Array()
	if has_lava_river_overlap:
		is_lava_river_vertex.resize(vert_count)
		lava_river_original_height.resize(vert_count)
		lava_river_flow_uv.resize(vert_count)

	# Per-vertex: dry_river_bed flag + flow-aligned UVs for pebble texture overlay.
	# The pebble material sits on the carved riverbed floor (post-depression).
	var is_dry_river_bed_vertex: PackedByteArray = PackedByteArray()
	var dry_river_bed_flow_uv: PackedVector2Array = PackedVector2Array()
	if has_dry_river_bed_overlap:
		is_dry_river_bed_vertex.resize(vert_count)
		dry_river_bed_flow_uv.resize(vert_count)

	# Per-vertex: river flag + original terrain height before V-depression.
	var is_river_vertex: PackedByteArray = PackedByteArray()
	var river_original_height: PackedFloat32Array = PackedFloat32Array()
	var river_cross_t: PackedFloat32Array = PackedFloat32Array()  # 0=center, 1=edge
	var river_along_t: PackedFloat32Array = PackedFloat32Array()  # 0=start, 1=end of river
	var river_zone_for_flow: Dictionary = {}
	if has_river_overlap:
		is_river_vertex.resize(vert_count)
		river_original_height.resize(vert_count)
		river_cross_t.resize(vert_count)
		river_along_t.resize(vert_count)

	# Per-vertex: road overlay flag.
	# Roads don't depress terrain — they're flat overlays above the surface.
	# The overlay mesh is built as an independent strip from centerline data,
	# but we still flag grid vertices for grass suppression (meadow_spawner).
	var is_road_vertex: PackedByteArray = PackedByteArray()
	if has_road_overlap:
		is_road_vertex.resize(vert_count)

	# How far the terrain is pushed below the water surface (metres).
	const LIQUID_DEPTH := 10.0
	# How far above the original terrain the water surface sits.
	const WATER_OFFSET := 2.0

	# Ensure the detail texture array is built so the shader has it.
	data.get_detail_texture_array()

	# ── Corundum whole-planet override ─────────────────────────────
	# When enabled, every vertex is coloured / detailed as the
	# aride_desert-corundum_plateau biome regardless of its real biome.
	# (Phase 2 will also carve the procedural crack network here.)
	var _corundum_bd: BiomeDefinition = null
	# Mesh vertex spacing (m) for this chunk — used to LOD-fade the crack carve
	# so mid-distance chunks don't alias the crack pattern into a spiky mess.
	var _crack_vtx_spacing := 0.0
	if data.corundum_override_whole_planet:
		_corundum_bd = data.get_biome_by_type(
				ArideDesertCorundumPlateauTerrain.BIOME_TYPE)
		if hp_mode and res > 0:
			_crack_vtx_spacing = HEALPix.pixel_side_length(hp_nside, 1.0) \
					* data.radius / float(res)
		if not _corundum_logged:
			_corundum_logged = true
			print("[PlanetChunk] corundum override ACTIVE on planet=%s  bd=%s  spacing=%.0f width=%.0f depth=%.0f" % [
				data.planet_name, str(_corundum_bd != null),
				data.crack_spacing_m, data.crack_width_m, data.crack_depth_m])

	# ── Recipe crater data ─────────────────────────────────────────
	# Craters from recipes are too small to resolve in the recipe heightmap
	# (sub-pixel at 128px / ~60km chunks).  Fetch cached recipe crater data
	# and apply displacement per-vertex instead.
	var recipe_craters: Array = []
	if not data.craters_baked:
		if hp_mode:
			var _crater_ipix := hp_ipix
			var _cur_nside := hp_nside
			while _cur_nside > data.export_nside:
				_crater_ipix = HEALPix.parent_pixel(_crater_ipix)
				_cur_nside /= 2
			while _cur_nside < data.export_nside:
				_crater_ipix = _crater_ipix * 4
				_cur_nside *= 2
			recipe_craters = data.get_chunk_craters(_crater_ipix)
		else:
			var _cpe := int(pow(2, data.chunk_export_depth))
			var _u_mid := (u_min + u_max) * 0.5
			var _v_mid := (v_min + v_max) * 0.5
			var _eu := clampi(int((_u_mid + 1.0) * 0.5 * _cpe), 0, _cpe - 1)
			var _ev := clampi(int((_v_mid + 1.0) * 0.5 * _cpe), 0, _cpe - 1)
			recipe_craters = []  # Legacy cube-sphere: craters only stored via HEALPix export

	# ── Pre-query compact craters for this chunk ───────────────────
	# Recipe craters are already cached; no BiomeQuery needed.
	var _chunk_compact_craters: Array = []
	if has_crater_overlap and not data.craters_baked:
		_chunk_compact_craters = _cr_arr

	# Record per-vertex height so the edge skirt can be sized from the steepest
	# single cell (the actual LOD-seam mismatch), not the whole-chunk relief.
	# Whole-chunk relief × exaggeration produced kilometre-deep skirt walls →
	# massive overdraw. The seam between a chunk and a 2× coarser neighbour is
	# only ~a couple of cells of slope, so a small multiple of the max cell step
	# covers it cheaply.
	var _chunk_heights := PackedFloat32Array()
	_chunk_heights.resize((res + 1) * (res + 1))

	# --- vertices -----------------------------------------------------------
	for yi in res + 1:
		for xi in res + 1:
			var idx := yi * (res + 1) + xi
			var dir: Vector3
			var height: float
			if hp_mode:
				dir = grid_dirs[yi][xi]
				# Boundary vertices may be shared with a chunk that has a different
				# _export_ipix (at HEALPix face or export-tile seams).
				# sample_height_boundary picks the same canonical export tile for
				# any given direction, so both sides of the seam are consistent.
				if xi == 0 or xi == res or yi == 0 or yi == res:
					height = data.sample_height_boundary(dir, _export_ipix)
				else:
					height = data.sample_height_for_direction(dir, _export_ipix)
			else:
				# Snap boundary vertices to exact u_min/u_max/v_min/v_max so
				# shared edges between adjacent chunks sample identical heights.
				var u: float
				if xi == 0:
					u = u_min
				elif xi == res:
					u = u_max
				else:
					u = u_min + xi * u_step
				var v: float
				if yi == 0:
					v = v_min
				elif yi == res:
					v = v_max
				else:
					v = v_min + yi * v_step
				dir = PlanetData.cube_to_sphere(face, u, v)
				height = data.sample_height_for_chunk(
						face, u, v, u_min, u_max, v_min, v_max)

			# ── Single biome query per vertex (from populate zones) ──────
			# Reused for liquid detection, colour, AND detail texture.
			var bd: BiomeDefinition = null
			var zone_color_hex: String = ""
			var first_zone: Dictionary = {}
			if not _pz_zones.is_empty():
				var _vz := _query_zones_at_direction(dir, _pz_zones)
				if not _vz.is_empty():
					first_zone = _vz[0]
					bd = data.get_biome_by_type(first_zone.get("biome_type", ""))
					zone_color_hex = first_zone.get("color_hex", "")

			# River depression — V-shaped cross-section with progressive width.
			# The recipe heightmap resolution (~122m/pixel at nside=64) is too
			# coarse to carve rivers that are typically 1–50m wide.  Carving is
			# therefore performed at runtime per-vertex.
			#
			# River zone lookup bypasses point-in-polygon (query_at_direction)
			# because the buffered polygon may be narrower than the vertex grid
			# spacing at coarse LODs — no grid vertex falls inside the polygon.
			# Instead, we compute get_cross_section_t directly from the cached
			# river zones found during the AABB pre-pass.
			if has_river_overlap:
				var lonlat := BiomeQuery._dir_to_lonlat(dir)
				var best_t: float = 1.0
				var best_along: float = 0.0
				var best_rzone: Dictionary = {}
				for _rz in _river_zones:
					var _rcl: PackedVector2Array = _rz.get("centerline", PackedVector2Array())
					if _rcl.size() < 2:
						continue
					var cs := BiomeQuery.get_cross_section_t(_rz, lonlat)
					var t: float = cs.t
					if t < best_t:
						best_t = t
						best_along = cs.along_t
						best_rzone = _rz
				if best_t < 1.0 and not best_rzone.is_empty():
					is_river_vertex[idx] = 1
					river_cross_t[idx] = best_t
					river_along_t[idx] = best_along
					# Progressive depth: interpolate width, then depth = width × 0.1.
					var ws: float = best_rzone.get("width_start_m", 0.0)
					var we: float = best_rzone.get("width_end_m", 0.0)
					var width_here: float
					if ws > 0.0 or we > 0.0:
						width_here = lerpf(ws, we, best_along)
					else:
						width_here = best_rzone.get("width", 10.0)
					var zdepth: float = width_here * MaritimeRiverRiverTerrain.DEPTH_RATIO
					if zdepth < 0.5:
						zdepth = 0.5
					# Store bank height, then carve the V-shaped depression
					# at runtime (recipe heightmap is too coarse for this).
					river_original_height[idx] = height
					height -= zdepth * (1.0 - best_t * best_t)
					if river_zone_for_flow.is_empty():
						river_zone_for_flow = best_rzone
				elif has_liquid_overlap and bd and bd.is_liquid:
					# Not inside a river — check for other liquid zones.
					is_liquid_vertex[idx] = 1
					original_height[idx] = height
					height -= LIQUID_DEPTH
			# Regular liquid depression (ocean, lake…) — only when no river overlap.
			elif has_liquid_overlap and bd and bd.is_liquid:
				is_liquid_vertex[idx] = 1
				original_height[idx] = height
				height -= LIQUID_DEPTH

			# Shallow water (swamp, bog) — no terrain depression.
			if has_shallow_water_overlap and bd and bd.has_shallow_water:
				is_shallow_water_vertex[idx] = 1

			# Volcanic active — flag for lava overlay surface.
			# Active volcanos are radial features, not populate zones.
			if has_volcanic_active_overlap:
				var _va_lonlat := BiomeQuery._dir_to_lonlat(dir)
				var _va_m_per_deg := data.radius * PI / 180.0
				for _va_rf in _rf_arr:
					if _va_rf.get("type", "") != "volcanic_geothermal-active_volcano":
						continue
					var _va_dx: float = (_va_lonlat.x - _va_rf.get("lon", 0.0)) * cos(deg_to_rad(_va_lonlat.y)) * _va_m_per_deg
					var _va_dy: float = (_va_lonlat.y - _va_rf.get("lat", 0.0)) * _va_m_per_deg
					var _va_dist: float = sqrt(_va_dx * _va_dx + _va_dy * _va_dy)
					if _va_dist < _va_rf.get("radius_m", 0.0):
						is_volcanic_active_vertex[idx] = 1
						break

			# Lunar ground — flag for lunar ground material overlay surface.
			if has_lunar_ground_overlap and bd \
					and SpatialLunarGroundTerrain.matches_zone(bd):
				is_lunar_ground_vertex[idx] = 1

			# Meadow — flag for grass ground material overlay surface.
			if has_meadow_overlap and bd \
					and MeadowSteppeMeadowTerrain.matches_zone(bd):
				is_meadow_vertex[idx] = 1

			# Forest ground — flag for leaf-litter material overlay surface.
			if has_forest_ground_overlap and bd \
					and ForestTemperateForestTerrain.matches_zone(bd):
				is_forest_ground_vertex[idx] = 1

			# Cliff — flag for cliff face material overlay surface.
			if has_cliff_overlap and bd \
					and RockyLandformCliffTerrain.matches_zone(bd):
				is_cliff_vertex[idx] = 1

			# Dry riverbed — flag for pebble texture overlay, with flow-aligned UVs.
			# The pebble surface follows the carved floor (post-depression vertices).
			if has_dry_river_bed_overlap:
				var _drb_lonlat := BiomeQuery._dir_to_lonlat(dir)
				var _drb_best_t: float = 1.0
				var _drb_best_zone: Dictionary = {}
				for _drbz in _dry_river_bed_zones:
					var _drb_cl: PackedVector2Array = _drbz.get("centerline", PackedVector2Array())
					if _drb_cl.size() < 2:
						continue
					var _drb_cs := BiomeQuery.get_cross_section_t(_drbz, _drb_lonlat)
					if _drb_cs.t < _drb_best_t:
						_drb_best_t = _drb_cs.t
						_drb_best_zone = _drbz
				if _drb_best_t < 1.0 and not _drb_best_zone.is_empty():
					is_dry_river_bed_vertex[idx] = 1
					var _drb_m_per_deg := data.radius * PI / 180.0
					var _drb_flow := BiomeQuery.get_flow_aligned_coords(
						_drb_best_zone, _drb_lonlat, _drb_m_per_deg)
					dry_river_bed_flow_uv[idx] = _drb_flow

			# Road overlay — query the separate road BiomeQuery.
			# Roads don't depress terrain; they are flat texture overlays.
			# The detection polygon is wider than the visual road, so
			# cross-section t < 1.0 determines which vertices get the overlay.
			if has_road_overlap and rq:
				var _rd_zones: Array[Dictionary] = rq.query_at_direction(dir)
				for _rd_z in _rd_zones:
					if not RoadTerrain.is_road_zone(_rd_z):
						continue
					RoadTerrain.prepare_zone(_rd_z, data.radius)
					var _rd_lonlat := BiomeQuery._dir_to_lonlat(dir)
					var _rd_cs := BiomeQuery.get_cross_section_t(_rd_z, _rd_lonlat)
					if _rd_cs.t < 1.0:
						is_road_vertex[idx] = 1
						break

			# Lava river — iterate recipe linear features for lava_river type.
			# The cross-section test (t < 1.0) determines which vertices
			# are actually inside the channel; only those get the lava
			# overlay flag AND the depression.
			if has_lava_river_overlap:
				for _lr_z in _lf_arr:
					if _lr_z.get("type", "") != "volcanic_geothermal-lava_river":
						continue
					var _lr_cl: PackedVector2Array = _lr_z.get("centerline", PackedVector2Array())
					if _lr_cl.size() < 2:
						continue
					VolcanicGeothermalLavaRiverTerrain.prepare_zone(_lr_z, data.radius)
					var _lr_lonlat := BiomeQuery._dir_to_lonlat(dir)
					var _lr_cs := BiomeQuery.get_cross_section_t(_lr_z, _lr_lonlat)
					var _lr_t: float = _lr_cs.t
					if _lr_t < 1.0:
						# Inside the actual channel — flag for overlay.
						is_lava_river_vertex[idx] = 1
						lava_river_original_height[idx] = height
						# Flow-aligned UV: U = along flow, V = across.
						var _lr_m_per_deg := data.radius * PI / 180.0
						var _lr_flow := BiomeQuery.get_flow_aligned_coords(
							_lr_z, _lr_lonlat, _lr_m_per_deg)
						lava_river_flow_uv[idx] = _lr_flow
						# Apply linear depression (U-profile).
						var _lr_depth: float = _lr_z.get("depth_override", 0.0)
						if _lr_depth <= 0.0:
							_lr_depth = VolcanicGeothermalLavaRiverTerrain.DEFAULT_DEPTH_M
						var _lr_t2 := _lr_t * _lr_t
						height -= _lr_depth * (1.0 - _lr_t2 * _lr_t2)
					break

			# Linear depression — steep-walled U-profile (1 − t⁴).
			# Iterates recipe linear features directly for canyon/crevasse types.
			if has_linear_overlap:
				var _lin_lonlat := BiomeQuery._dir_to_lonlat(dir)
				for _lin_z in _lf_arr:
					var _lin_type: String = _lin_z.get("type", "")
					# Lava river and water river handled by their own sections.
					if _lin_type == "volcanic_geothermal-lava_river" \
							or _lin_type == "maritime_river-river":
						continue
					var _lin_cl: PackedVector2Array = _lin_z.get("centerline", PackedVector2Array())
					if _lin_cl.size() < 2:
						continue
					var _lin_depth_m: float = RockyLandformCanyonTerrain.DEFAULT_DEPTH_M
					match _lin_type:
						"rocky_landform-canyon":
							RockyLandformCanyonTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = RockyLandformCanyonTerrain.DEFAULT_DEPTH_M
						"icy-ice_crevasse":
							IcyIceCrevasseTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = IcyIceCrevasseTerrain.DEFAULT_DEPTH_M
						"aride_desert-dry_river_bed":
							ArideDesertDryRiverBedTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = ArideDesertDryRiverBedTerrain.DEFAULT_DEPTH_M
						"rocky_landform-pressure_canyon":
							RockyLandformPressureCanyonTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = RockyLandformPressureCanyonTerrain.DEFAULT_DEPTH_M
						_:
							RockyLandformCanyonTerrain.prepare_zone(_lin_z, data.radius)
					var _lin_cs := BiomeQuery.get_cross_section_t(_lin_z, _lin_lonlat)
					var _lin_t: float = _lin_cs.t
					if _lin_t < 1.0:
						var cdepth: float = _lin_z.get("depth_override", 0.0)
						if cdepth <= 0.0:
							cdepth = _lin_depth_m
						var t2 := _lin_t * _lin_t
						height -= cdepth * (1.0 - t2 * t2)
						break

			# Point depression — radial funnel around polygon centroid.
			# Cave uses vertex-collapse hole; others use smooth bowl.
			# Active volcano depression is baked in recipe heightmap (radial feature).
			if has_point_overlap and bd:
				var _pt_radius: float = 0.0
				var _pt_depth: float = 0.0
				var _pt_hole_radius: float = 0.0
				var _pt_has_hole := false
				if CaveTerrain.is_cave_biome(bd):
					_pt_radius = CaveTerrain.ENTRANCE_RADIUS_M
					_pt_depth = CaveTerrain.ENTRANCE_DEPTH_M
					_pt_hole_radius = CaveTerrain.HOLE_RADIUS_M
					_pt_has_hole = true
				elif VolcanicGeothermalFumaroleTerrain.matches_zone(bd):
					_pt_radius = VolcanicGeothermalFumaroleTerrain.DEPRESSION_RADIUS_M
					_pt_depth = VolcanicGeothermalFumaroleTerrain.DEPRESSION_DEPTH_M
				elif VolcanicGeothermalIceGeyserTerrain.matches_zone(bd):
					_pt_radius = VolcanicGeothermalIceGeyserTerrain.DEPRESSION_RADIUS_M
					_pt_depth = VolcanicGeothermalIceGeyserTerrain.DEPRESSION_DEPTH_M
				elif VolcanicGeothermalMineralThermalSourceTerrain.matches_zone(bd):
					_pt_radius = VolcanicGeothermalMineralThermalSourceTerrain.DEPRESSION_RADIUS_M
					_pt_depth = VolcanicGeothermalMineralThermalSourceTerrain.DEPRESSION_DEPTH_M
				if _pt_radius > 0.0:
					# Determine centroid from populate zone structure.
					var centroid := Vector2.ZERO
					var _pz_cov: String = first_zone.get("coverage", "")
					var _has_centroid := false
					if _pz_cov == "point":
						centroid = Vector2(first_zone.get("lon", 0.0), first_zone.get("lat", 0.0))
						_has_centroid = true
					else:
						var _pz_verts: Array = first_zone.get("vertices", [])
						if _pz_verts.size() >= 3:
							for _pv in _pz_verts:
								centroid += Vector2(_pv[0], _pv[1])
							centroid /= float(_pz_verts.size())
							_has_centroid = true
					if _has_centroid:
						var lonlat := BiomeQuery._dir_to_lonlat(dir)
						var m_per_deg := data.radius * PI / 180.0
						var dist_m := (lonlat - centroid).length() * m_per_deg
						if dist_m < _pt_radius:
							if _pt_has_hole and dist_m < _pt_hole_radius:
								# Cave-style vertex collapse — creates a real hole.
								var hole_centre_dir := CaveTerrain.lonlat_to_dir(centroid)
								var hole_pos := hole_centre_dir * (data.radius + height - _pt_depth)
								vertices[idx] = _world_to_local(hole_pos, cc_f32, _wp_f32)
								normals[idx]  = dir
								uvs[idx]      = PlanetData.direction_to_uv(dir)
								continue
							else:
								# Smooth taper depression.
								var _t_outer: float
								if _pt_has_hole:
									_t_outer = (dist_m - _pt_hole_radius) / (_pt_radius - _pt_hole_radius)
								else:
									_t_outer = dist_m / _pt_radius
								height -= _pt_depth * (1.0 - _t_outer * _t_outer)

			# ── Recipe crater displacement ─────────────────────────
			# Sub-pixel craters from recipe JSON, applied per-vertex
			# because the recipe heightmap is too coarse to resolve them.
			if not recipe_craters.is_empty():
				height += SpatialCraterTerrain.apply_craters(
					dir, recipe_craters, data.radius)

			# ── Cliff displacement ─────────────────────────────────
			# Vertices inside the cliff polygon are pushed down to form
			# a steep drop at the polygon boundary.
			if has_cliff_overlap and bd and RockyLandformCliffTerrain.matches_zone(bd):
				var _cl_poly: PackedVector2Array = first_zone.get("polygon", PackedVector2Array())
				if _cl_poly.size() >= 3:
					var _cl_lonlat := BiomeQuery._dir_to_lonlat(dir)
					var _cl_m_per_deg := data.radius * PI / 180.0
					var _cl_dist_deg := BiomeQuery._dist_to_polygon_edge(_cl_lonlat, _cl_poly)
					var _cl_dist_m := _cl_dist_deg * _cl_m_per_deg
					var _cl_drop: float = first_zone.get("depth", 0.0)
					if _cl_drop <= 0.0:
						_cl_drop = RockyLandformCliffTerrain.DROP_M
					height -= RockyLandformCliffTerrain.height_offset(_cl_dist_m, _cl_drop)

			# ── Corundum crack network ─────────────────────────────
			# Pure function of dir + PlanetData params → identical on the
			# server collision path (see generate_collision_shape).  Gate the
			# GEOMETRY on the override flag (not the biome definition) so the
			# visual carve always matches collision — the biome definition is
			# only needed below for the crack COLOUR staining.
			# Offset (≤ 0) is reused below to stain the crack interiors.
			var _crack_off := 0.0
			if data.corundum_override_whole_planet:
				_crack_off = ArideDesertCorundumPlateauTerrain.crack_offset(
					dir, data.radius, data.crack_spacing_m,
					data.crack_width_m, data.crack_depth_m, _crack_vtx_spacing)
				height += _crack_off

			_chunk_heights[idx] = height
			vertices[idx] = _world_to_local(dir * (data.radius + height), cc_f32, _wp_f32)
			normals[idx]  = dir  # placeholder — overwritten below
			uvs[idx]      = PlanetData.direction_to_uv(dir)

			# ── Biome colour ────────────────────────────────────────
			# Use the single biome query result directly.  The GPU's
			# hardware vertex-colour interpolation across triangles smooths
			# boundaries at ~6 m spacing, making expensive multi-sample
			# jittering unnecessary.
			var base_col := Color(0.45, 0.35, 0.25)  # fallback
			if _corundum_bd:
				# Milky-white ↔ iron-yellow mottling ("iron impurities"),
				# then darken/stain the interiors of the cracks.
				base_col = ArideDesertCorundumPlateauTerrain.iron_tint(
					dir, data.radius, _corundum_bd.color)
				base_col = ArideDesertCorundumPlateauTerrain.crack_stain(
					base_col, _crack_off, data.crack_depth_m)
			elif bd:
				base_col = bd.color
			elif not zone_color_hex.is_empty():
				base_col = Color(zone_color_hex)
			else:
				base_col = data.sample_biome_at(dir)
			colors[idx] = base_col

			# Detail texture info → UV2.
			var _detail_bd: BiomeDefinition = _corundum_bd if _corundum_bd else bd
			var detail_layer := data.get_detail_layer(_detail_bd)
			var detail_scale := data.get_detail_scale_for_layer(detail_layer)
			uv2s[idx] = Vector2(float(detail_layer), detail_scale)

	# --- indices (two triangles per quad) -----------------------------------
	indices.resize(res * res * 6)
	var ii := 0
	for yi in res:
		for xi in res:
			var i := yi * (res + 1) + xi
			indices[ii]     = i
			indices[ii + 1] = i + res + 1
			indices[ii + 2] = i + 1
			indices[ii + 3] = i + 1
			indices[ii + 4] = i + res + 1
			indices[ii + 5] = i + res + 2
			ii += 6

	# --- triangle winding correction ----------------------------------------
	# HEALPix base faces (and cube-sphere faces) have inconsistent (xi, yi)
	# grid orientations relative to the outward sphere normal.  For some
	# faces the iteration produces CCW triangles when viewed from outside
	# (correct for CULL_BACK), for others CW (treated as back-faces and
	# culled — the chunk renders invisible while skirts remain visible).
	# Detect the actual winding using the first triangle's geometric normal
	# vs an outward reference direction; if reversed, swap the second and
	# third index of every triangle.
	if indices.size() >= 3 and vertices.size() > indices[2]:
		var v0: Vector3 = vertices[indices[0]]
		var v1: Vector3 = vertices[indices[1]]
		var v2: Vector3 = vertices[indices[2]]
		var tri_n := (v1 - v0).cross(v2 - v0)
		var outward_ref: Vector3
		if hp_mode:
			outward_ref = grid_dirs[0][0]
		else:
			outward_ref = PlanetData.cube_to_sphere(face, u_min, v_min)
		if tri_n.dot(outward_ref) < 0.0:
			var swapped := PackedInt32Array()
			swapped.resize(indices.size())
			var jj := 0
			while jj < indices.size():
				swapped[jj]     = indices[jj]
				swapped[jj + 1] = indices[jj + 2]
				swapped[jj + 2] = indices[jj + 1]
				jj += 3
			indices = swapped

	# --- smooth normals from analytical heightmap gradient -------------------
	# Previously we used _recalculate_normals (face-accumulated) for interior
	# vertices and analytical gradient only for boundary vertices.  The two
	# methods produced slightly different normals, causing a visible dark band
	# at the edge-to-interior transition.
	# Fix: compute analytical normals for ALL vertices.  The heightmap gradient
	# is the "true" normal and is consistent across chunk boundaries, so every
	# vertex uses the same method — no transition artifact.
	if hp_mode:
		var _eps_frac := 0.25 / float(res)
		for yi in res + 1:
			for xi in res + 1:
				var idx := yi * (res + 1) + xi
				var dir_c: Vector3 = grid_dirs[yi][xi]
				# Build tangent frame on sphere at this vertex.
				var up := dir_c
				var arbitrary := Vector3.UP if absf(up.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
				var tan_u := up.cross(arbitrary).normalized()
				var tan_v := up.cross(tan_u).normalized()
				var eps_rad := HEALPix.pixel_side_length(hp_nside, 1.0) * _eps_frac
				var dir_l := (dir_c - tan_u * eps_rad).normalized()
				var dir_r := (dir_c + tan_u * eps_rad).normalized()
				var dir_b := (dir_c - tan_v * eps_rad).normalized()
				var dir_t := (dir_c + tan_v * eps_rad).normalized()
				# Edge vertices: use sample_height_boundary so both sides of
				# a chunk seam resolve to the same canonical export tile →
				# identical normals.  Interior vertices can use the fast path.
				var h_l: float
				var h_r: float
				var h_b: float
				var h_t: float
				if xi == 0 or xi == res or yi == 0 or yi == res:
					h_l = data.sample_height_boundary(dir_l, _export_ipix)
					h_r = data.sample_height_boundary(dir_r, _export_ipix)
					h_b = data.sample_height_boundary(dir_b, _export_ipix)
					h_t = data.sample_height_boundary(dir_t, _export_ipix)
				else:
					h_l = data.sample_height_for_direction(dir_l, _export_ipix)
					h_r = data.sample_height_for_direction(dir_r, _export_ipix)
					h_b = data.sample_height_for_direction(dir_b, _export_ipix)
					h_t = data.sample_height_for_direction(dir_t, _export_ipix)
				# Carve the crack network into the gradient samples too, so the
				# near-vertical crack walls get correct (sharp) shading normals.
				if data.corundum_override_whole_planet:
					h_l += ArideDesertCorundumPlateauTerrain.crack_offset(
						dir_l, data.radius, data.crack_spacing_m, data.crack_width_m, data.crack_depth_m, _crack_vtx_spacing)
					h_r += ArideDesertCorundumPlateauTerrain.crack_offset(
						dir_r, data.radius, data.crack_spacing_m, data.crack_width_m, data.crack_depth_m, _crack_vtx_spacing)
					h_b += ArideDesertCorundumPlateauTerrain.crack_offset(
						dir_b, data.radius, data.crack_spacing_m, data.crack_width_m, data.crack_depth_m, _crack_vtx_spacing)
					h_t += ArideDesertCorundumPlateauTerrain.crack_offset(
						dir_t, data.radius, data.crack_spacing_m, data.crack_width_m, data.crack_depth_m, _crack_vtx_spacing)
				var world_l := dir_l * (data.radius + h_l)
				var world_r := dir_r * (data.radius + h_r)
				var world_b := dir_b * (data.radius + h_b)
				var world_t := dir_t * (data.radius + h_t)
				var tangent_u := world_r - world_l
				var tangent_v := world_t - world_b
				var n := tangent_u.cross(tangent_v)
				# HEALPix face winding varies between base pixels — flip if the
				# computed normal points inward (away from the surface).
				if n.dot(dir_c) < 0.0:
					n = -n
				if n.length_squared() > 0.0:
					normals[idx] = n.normalized()
				else:
					normals[idx] = dir_c
	else:
		# Cube-sphere path: analytical normals for all vertices too.
		var _eps_u := u_step * 0.25
		var _eps_v := v_step * 0.25
		for yi in res + 1:
			for xi in res + 1:
				var idx := yi * (res + 1) + xi
				var u: float
				if xi == 0:
					u = u_min
				elif xi == res:
					u = u_max
				else:
					u = u_min + xi * u_step
				var v: float
				if yi == 0:
					v = v_min
				elif yi == res:
					v = v_max
				else:
					v = v_min + yi * v_step
				var u_l := maxf(u - _eps_u, -1.0)
				var u_r := minf(u + _eps_u, 1.0)
				var v_b := maxf(v - _eps_v, -1.0)
				var v_t := minf(v + _eps_v, 1.0)
				var h_l: float = data.sample_height_for_chunk(face, u_l, v, u_min, u_max, v_min, v_max)
				var h_r: float = data.sample_height_for_chunk(face, u_r, v, u_min, u_max, v_min, v_max)
				var h_b: float = data.sample_height_for_chunk(face, u, v_b, u_min, u_max, v_min, v_max)
				var h_t: float = data.sample_height_for_chunk(face, u, v_t, u_min, u_max, v_min, v_max)
				var dir_l: Vector3 = PlanetData.cube_to_sphere(face, u_l, v) * (data.radius + h_l)
				var dir_r: Vector3 = PlanetData.cube_to_sphere(face, u_r, v) * (data.radius + h_r)
				var dir_b: Vector3 = PlanetData.cube_to_sphere(face, u, v_b) * (data.radius + h_b)
				var dir_t: Vector3 = PlanetData.cube_to_sphere(face, u, v_t) * (data.radius + h_t)
				var tangent_u: Vector3 = dir_r - dir_l
				var tangent_v: Vector3 = dir_t - dir_b
				var n: Vector3 = tangent_u.cross(tangent_v)
				# Cube face winding varies — flip if the normal points inward.
				var _outward: Vector3 = PlanetData.cube_to_sphere(face, u, v)
				if n.dot(_outward) < 0.0:
					n = -n
				if n.length_squared() > 0.0:
					normals[idx] = n.normalized()
				else:
					normals[idx] = _outward

	# --- skirt geometry to hide chunk boundary seams -------------------------
	# Duplicate every edge vertex, nudge outward from the chunk interior
	# (so the skirt overlaps slightly with the neighbour's terrain), then
	# drop toward the planet centre.  The outward nudge ensures micro-gaps
	# between adjacent chunks are always covered by overlapping skirts.
	# Skirt depth = a small multiple of the steepest single-cell height step, which
	# is what actually has to be bridged where this chunk meets a coarser-LOD
	# neighbour. Sizing from whole-chunk relief (× exaggeration) produced
	# kilometre-deep walls and crushing overdraw; the seam mismatch is only a
	# couple of cells of slope, so max_step × 6 (+ margin) covers it cheaply.
	var _max_step := 0.0
	var _stride := res + 1
	for _yi in res + 1:
		for _xi in res + 1:
			var _i := _yi * _stride + _xi
			var _hc := _chunk_heights[_i]
			if _xi > 0:
				_max_step = maxf(_max_step, absf(_hc - _chunk_heights[_i - 1]))
			if _yi > 0:
				_max_step = maxf(_max_step, absf(_hc - _chunk_heights[_i - _stride]))
	var skirt_drop := maxf(_max_step * 6.0 + 25.0, 40.0)  # metres below surface
	# Corundum cracks create ~crack_depth single-cell steps, which would inflate
	# skirt_drop into kilometre-tall walls (overdraw + dark vertical faces at LOD
	# seams).  A LOD-seam mismatch never exceeds the crack depth, so cap it there.
	if _corundum_bd:
		skirt_drop = minf(skirt_drop, data.crack_depth_m * 1.5 + 40.0)
	var skirt_nudge := 0.1  # metres along surface, outward from chunk interior
	var edge_indices_list: Array[int] = []
	# Bottom edge (yi == 0, all xi)
	for xi in res + 1:
		edge_indices_list.append(0 * (res + 1) + xi)
	# Top edge (yi == res, all xi)
	for xi in res + 1:
		edge_indices_list.append(res * (res + 1) + xi)
	# Left edge (xi == 0, yi 1..res-1) — corners already included above
	for yi in range(1, res):
		edge_indices_list.append(yi * (res + 1) + 0)
	# Right edge (xi == res, yi 1..res-1)
	for yi in range(1, res):
		edge_indices_list.append(yi * (res + 1) + res)

	# Map: original vertex index → skirt (dropped) vertex index
	var skirt_map: Dictionary = {}
	for ei in edge_indices_list:
		if skirt_map.has(ei):
			continue
		var world_pos := vertices[ei] + cc_f32
		var dir_s := world_pos.normalized()
		# Compute outward nudge: push the skirt base slightly beyond the
		# chunk edge so it tucks under the neighbour's terrain surface.
		var _sk_xi: int = ei % (res + 1)
		@warning_ignore("integer_division")
		var _sk_yi: int = ei / (res + 1)
		var nudge := Vector3.ZERO
		if _sk_yi == 0:  # bottom edge → nudge toward yi = -1
			nudge += vertices[ei] - vertices[1 * (res + 1) + _sk_xi]
		if _sk_yi == res:  # top edge → nudge toward yi = res+1
			nudge += vertices[ei] - vertices[(res - 1) * (res + 1) + _sk_xi]
		if _sk_xi == 0:  # left edge → nudge toward xi = -1
			nudge += vertices[ei] - vertices[_sk_yi * (res + 1) + 1]
		if _sk_xi == res:  # right edge → nudge toward xi = res+1
			nudge += vertices[ei] - vertices[_sk_yi * (res + 1) + (res - 1)]
		# Project onto tangent plane and scale to SKIRT_NUDGE metres.
		if nudge.length_squared() > 0.0:
			nudge = nudge - dir_s * nudge.dot(dir_s)
			if nudge.length_squared() > 0.0:
				nudge = nudge.normalized() * skirt_nudge
		var dropped := _world_to_local(world_pos + nudge - dir_s * skirt_drop, cc_f32, _wp_f32)
		var surface_local := vertices[ei]
		var surface_offset := surface_local - dropped
		var skirt_idx := vertices.size()
		# Store the DROPPED position directly as VERTEX so the geometry is
		# correct even without shader support for CUSTOM0.  CUSTOM0 holds
		# the inverse offset (dropped → surface) so the shader can recover
		# the surface position for triplanar UV continuity:
		#   surface_pos = VERTEX + CUSTOM0
		vertices.append(dropped)
		normals.append(normals[ei])
		uvs.append(uvs[ei])
		uv2s.append(uv2s[ei])
		# Debug: paint skirt curtains bright magenta so they can be told apart
		# from real terrain / crack interiors in-game.
		colors.append(Color.MAGENTA if data.debug_color_skirts else colors[ei])
		skirt_offsets.append(surface_offset.x)
		skirt_offsets.append(surface_offset.y)
		skirt_offsets.append(surface_offset.z)
		skirt_map[ei] = skirt_idx

	# Connect skirt triangles along each continuous edge strip.
	# For each consecutive pair of edge vertices (a, b), form a quad
	# with their dropped counterparts (sa, sb) → 2 triangles.
	# Bottom edge (left to right)
	for xi in res:
		var a := 0 * (res + 1) + xi
		var b := 0 * (res + 1) + xi + 1
		var sa: int = skirt_map[a]
		var sb: int = skirt_map[b]
		indices.append(a);  indices.append(sa); indices.append(b)
		indices.append(b);  indices.append(sa); indices.append(sb)
	# Top edge (left to right)
	for xi in res:
		var a := res * (res + 1) + xi
		var b := res * (res + 1) + xi + 1
		var sa: int = skirt_map[a]
		var sb: int = skirt_map[b]
		indices.append(a);  indices.append(b);  indices.append(sa)
		indices.append(b);  indices.append(sb); indices.append(sa)
	# Left edge (bottom to top)
	for yi in res:
		var a := yi * (res + 1) + 0
		var b := (yi + 1) * (res + 1) + 0
		var sa: int = skirt_map[a]
		var sb: int = skirt_map[b]
		indices.append(a);  indices.append(b);  indices.append(sa)
		indices.append(b);  indices.append(sb); indices.append(sa)
	# Right edge (bottom to top)
	for yi in res:
		var a := yi * (res + 1) + res
		var b := (yi + 1) * (res + 1) + res
		var sa: int = skirt_map[a]
		var sb: int = skirt_map[b]
		indices.append(a);  indices.append(sa); indices.append(b)
		indices.append(b);  indices.append(sa); indices.append(sb)

	# --- collect volcanic_active quad indices for lava surface ---------------
	# Volcanic quads are excluded from the base terrain surface and drawn on a
	# separate surface with their own ORMMaterial3D.  No z-fighting because
	# the quads don't overlap.
	var lava_indices := PackedInt32Array()
	if has_volcanic_active_overlap:
		for qi in range(0, res * res * 6, 6):
			var i00 := indices[qi]
			var i01 := indices[qi + 1]
			var i10 := indices[qi + 2]
			var i11 := indices[qi + 5]
			if is_volcanic_active_vertex[i00] == 1 \
					or is_volcanic_active_vertex[i10] == 1 \
					or is_volcanic_active_vertex[i01] == 1 \
					or is_volcanic_active_vertex[i11] == 1:
				for oi in range(qi, qi + 6):
					lava_indices.append(indices[oi])

	# --- collect lunar_ground quad indices for material overlay ---
	var lunar_ground_indices := PackedInt32Array()
	if has_lunar_ground_overlap:
		for qi in range(0, res * res * 6, 6):
			var i00 := indices[qi]
			var i01 := indices[qi + 1]
			var i10 := indices[qi + 2]
			var i11 := indices[qi + 5]
			if is_lunar_ground_vertex[i00] == 1 \
					or is_lunar_ground_vertex[i10] == 1 \
					or is_lunar_ground_vertex[i01] == 1 \
					or is_lunar_ground_vertex[i11] == 1:
				for oi in range(qi, qi + 6):
					lunar_ground_indices.append(indices[oi])

	# --- collect meadow quad indices for grass ground overlay ---
	var meadow_indices := PackedInt32Array()
	if has_meadow_overlap:
		for qi in range(0, res * res * 6, 6):
			var i00 := indices[qi]
			var i01 := indices[qi + 1]
			var i10 := indices[qi + 2]
			var i11 := indices[qi + 5]
			if is_meadow_vertex[i00] == 1 \
					or is_meadow_vertex[i10] == 1 \
					or is_meadow_vertex[i01] == 1 \
					or is_meadow_vertex[i11] == 1:
				for oi in range(qi, qi + 6):
					meadow_indices.append(indices[oi])

	# --- collect forest_ground quad indices for leaf-litter overlay ---
	var forest_ground_indices := PackedInt32Array()
	if has_forest_ground_overlap:
		for qi in range(0, res * res * 6, 6):
			var i00 := indices[qi]
			var i01 := indices[qi + 1]
			var i10 := indices[qi + 2]
			var i11 := indices[qi + 5]
			if is_forest_ground_vertex[i00] == 1 \
					or is_forest_ground_vertex[i10] == 1 \
					or is_forest_ground_vertex[i01] == 1 \
					or is_forest_ground_vertex[i11] == 1:
				for oi in range(qi, qi + 6):
					forest_ground_indices.append(indices[oi])

	# --- collect cliff face indices for steep triangles only ---------------
	# Only triangles within the cliff biome whose face normal is steep
	# (dot with planet-up < SLOPE_THRESHOLD) get the cliff ORMMaterial3D.
	var cliff_indices := PackedInt32Array()
	if has_cliff_overlap:
		for qi in range(0, res * res * 6, 6):
			var i00 := indices[qi]
			var i01 := indices[qi + 1]
			var i10 := indices[qi + 2]
			var i11 := indices[qi + 5]
			# At least one vertex must belong to the cliff biome.
			if is_cliff_vertex[i00] == 0 \
					and is_cliff_vertex[i10] == 0 \
					and is_cliff_vertex[i01] == 0 \
					and is_cliff_vertex[i11] == 0:
				continue
			# Check the two triangles' face normals for steepness.
			# Use absf() because cross-product winding may flip across
			# cube faces, producing an inward-facing normal.
			for ti in 2:
				var oi := qi + ti * 3
				var a := vertices[indices[oi]] + chunk_center
				var b := vertices[indices[oi + 1]] + chunk_center
				var c := vertices[indices[oi + 2]] + chunk_center
				var face_normal := (b - a).cross(c - a).normalized()
				var planet_up := ((a + b + c) / 3.0).normalized()
				if absf(face_normal.dot(planet_up)) < RockyLandformCliffTerrain.SLOPE_THRESHOLD:
					for k in 3:
						cliff_indices.append(indices[oi + k])

	# (lava_river quad collection removed — the lava surface is now built
	#  as a separate vertex mesh like the river water overlay, see below.)

	# --- exclude overlay quads from base terrain surface --------------------
	# When an overlay (lava, lunar, meadow, forest, cliff) covers a quad, the
	# two different shader programs (ShaderMaterial base vs ORMMaterial3D
	# overlay) produce subtly different fragment depths for the same vertex
	# positions, causing z-fighting sparkle.  Removing covered quads from the
	# base surface eliminates the overlap entirely.
	var _grid_quad_count := res * res
	var _quad_has_overlay := PackedByteArray()
	_quad_has_overlay.resize(_grid_quad_count)
	# Mark quads that appear in any overlay.
	for qi in range(0, _grid_quad_count * 6, 6):
		var qi_idx := qi / 6
		var i00 := indices[qi]
		var i10 := indices[qi + 2]
		var i01 := indices[qi + 1]
		var i11 := indices[qi + 5]
		if (has_volcanic_active_overlap \
					and (is_volcanic_active_vertex[i00] == 1 \
					or is_volcanic_active_vertex[i10] == 1 \
					or is_volcanic_active_vertex[i01] == 1 \
					or is_volcanic_active_vertex[i11] == 1)) \
				or (has_lunar_ground_overlap \
					and (is_lunar_ground_vertex[i00] == 1 \
					or is_lunar_ground_vertex[i10] == 1 \
					or is_lunar_ground_vertex[i01] == 1 \
					or is_lunar_ground_vertex[i11] == 1)) \
				or (has_meadow_overlap \
					and (is_meadow_vertex[i00] == 1 \
					or is_meadow_vertex[i10] == 1 \
					or is_meadow_vertex[i01] == 1 \
					or is_meadow_vertex[i11] == 1)) \
				or (has_forest_ground_overlap \
					and (is_forest_ground_vertex[i00] == 1 \
					or is_forest_ground_vertex[i10] == 1 \
					or is_forest_ground_vertex[i01] == 1 \
					or is_forest_ground_vertex[i11] == 1)) \
				or (has_cliff_overlap \
					and (is_cliff_vertex[i00] == 1 \
					or is_cliff_vertex[i10] == 1 \
					or is_cliff_vertex[i01] == 1 \
					or is_cliff_vertex[i11] == 1)):
			_quad_has_overlay[qi_idx] = 1
	# Build filtered base indices: non-overlay grid quads + all skirt tris.
	var base_indices := PackedInt32Array()
	for qi_idx in _grid_quad_count:
		if _quad_has_overlay[qi_idx] == 0:
			var qi := qi_idx * 6
			for oi in range(qi, qi + 6):
				base_indices.append(indices[oi])
	# Append skirt triangles (everything after grid quads in indices).
	var _skirt_start := _grid_quad_count * 6
	for si in range(_skirt_start, indices.size()):
		base_indices.append(indices[si])

	# --- compute tangents ---------------------------------------------------
	# Required for normal-mapped terrain materials. We compute tangents
	# inline (rather than via SurfaceTool) to preserve UV2 / COLOR /
	# CUSTOM0(skirt_offsets) which SurfaceTool's tangent path would
	# complicate. Standard per-triangle accumulation, then ortho-normalize
	# against the vertex normal and pack as Vector4(t.xyz, sign).
	var tangents := _compute_tangents(vertices, normals, uvs, base_indices)

	# --- build mesh ---------------------------------------------------------
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]  = vertices
	arrays[Mesh.ARRAY_NORMAL]  = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV]  = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR]   = colors
	arrays[Mesh.ARRAY_INDEX]   = base_indices
	arrays[Mesh.ARRAY_CUSTOM0] = skirt_offsets

	var mesh := ArrayMesh.new()
	var _c0_fmt := Mesh.ARRAY_CUSTOM_RGB_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, _c0_fmt)

	# Apply terrain material — use the one from PlanetData if provided,
	# otherwise fall back to a default vertex-colour material.
	if data.terrain_material:
		mesh.surface_set_material(0, data.terrain_material)
	else:
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.cull_mode = BaseMaterial3D.CULL_BACK
		mesh.surface_set_material(0, mat)

	# --- volcanic_active: lava material on top of the terrain ---------------
	# Overlay quads are excluded from the base terrain surface (see above),
	# so these surfaces REPLACE the base terrain for their quads rather than
	# overdrawing.  No z-fighting is possible because there is no overlapping
	# geometry.  cull_disabled matches the base terrain shader.

	if lava_indices.size() > 0:
		var lava_mat: Material = data.get_lava_material()
		if lava_mat:
			lava_mat = lava_mat.duplicate() as Material
			if lava_mat is BaseMaterial3D:
				(lava_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
			var lv_arrays: Array = []
			lv_arrays.resize(Mesh.ARRAY_MAX)
			lv_arrays[Mesh.ARRAY_VERTEX]  = vertices
			lv_arrays[Mesh.ARRAY_NORMAL]  = normals
			lv_arrays[Mesh.ARRAY_TEX_UV]  = uvs
			lv_arrays[Mesh.ARRAY_TEX_UV2] = uv2s
			lv_arrays[Mesh.ARRAY_COLOR]   = colors
			lv_arrays[Mesh.ARRAY_INDEX]   = lava_indices
			var lv_surface_idx := mesh.get_surface_count()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, lv_arrays)
			mesh.surface_set_material(lv_surface_idx, lava_mat)

	# --- lunar ground: ORMMaterial3D overlay on lunar ground terrain ----------
	# Build local tiling UVs from world-space position so the texture repeats
	# at a natural scale.  No vertex colours — the material's own albedo,
	# ORM and normal textures provide all visual detail.
	if lunar_ground_indices.size() > 0:
		var reg_mat: Material = data.get_lunar_ground_material()
		if reg_mat:
			reg_mat = reg_mat.duplicate() as Material
			if reg_mat is BaseMaterial3D:
				(reg_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
				# Disable deep parallax — each chunk has independent normals so
				# POM ray-marching produces different offsets at chunk seams.
				(reg_mat as BaseMaterial3D).heightmap_enabled = false
			# Build tiling UVs from vertex world position.
			# Subtract a chunk-level integer-tile offset so UV values stay
			# near zero — prevents float32 precision loss on the GPU.
			const LUNAR_GROUND_TILE_M := 8.0  # texture repeats every 8 metres
			var _rg_cd := chunk_center.normalized()
			var _rg_clon := atan2(_rg_cd.z, _rg_cd.x)
			var _rg_clat := asin(clampf(_rg_cd.y, -1.0, 1.0))
			var _rg_u_off := floorf(_rg_clon * data.radius / LUNAR_GROUND_TILE_M)
			var _rg_v_off := floorf(_rg_clat * data.radius / LUNAR_GROUND_TILE_M)
			var rg_uvs := PackedVector2Array()
			rg_uvs.resize(vertices.size())
			for vi in vertices.size():
				# vertices are chunk-local; add chunk_center for world pos.
				var world_pos := vertices[vi] + chunk_center
				var d := world_pos.normalized()
				# Project onto tangent plane using lon/lat.
				var lon := atan2(d.z, d.x)
				var lat := asin(clampf(d.y, -1.0, 1.0))
				# Arc-length in metres along surface.
				var x_m := lon * data.radius
				var y_m := lat * data.radius
				rg_uvs[vi] = Vector2(x_m / LUNAR_GROUND_TILE_M - _rg_u_off, y_m / LUNAR_GROUND_TILE_M - _rg_v_off)
			var rg_arrays: Array = []
			rg_arrays.resize(Mesh.ARRAY_MAX)
			rg_arrays[Mesh.ARRAY_VERTEX]  = vertices
			rg_arrays[Mesh.ARRAY_NORMAL]  = normals
			rg_arrays[Mesh.ARRAY_TEX_UV]  = rg_uvs
			rg_arrays[Mesh.ARRAY_INDEX]   = lunar_ground_indices
			var rg_surface_idx := mesh.get_surface_count()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, rg_arrays)
			mesh.surface_set_material(rg_surface_idx, reg_mat)

	# --- meadow: grass ground texture overlay on meadow terrain -------
	# Same pattern as lunar ground — an additional mesh surface with tiled UVs
	# and the grass_ground ORMMaterial3D drawn on top of the base terrain,
	# giving a grassy ground beneath the 3D grass blade MultiMesh.
	if meadow_indices.size() > 0:
		var gl_mat: Material = data.get_meadow_material()
		if gl_mat:
			gl_mat = gl_mat.duplicate() as Material
			if gl_mat is BaseMaterial3D:
				(gl_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
				# Disable deep parallax — each chunk has independent normals so
				# POM ray-marching produces different offsets at chunk seams.
				(gl_mat as BaseMaterial3D).heightmap_enabled = false
			const GRASS_TILE_M := 4.0  # grass texture repeats every 4 metres
			var _gl_cd := chunk_center.normalized()
			var _gl_clon := atan2(_gl_cd.z, _gl_cd.x)
			var _gl_clat := asin(clampf(_gl_cd.y, -1.0, 1.0))
			var _gl_u_off := floorf(_gl_clon * data.radius / GRASS_TILE_M)
			var _gl_v_off := floorf(_gl_clat * data.radius / GRASS_TILE_M)
			var gl_uvs := PackedVector2Array()
			gl_uvs.resize(vertices.size())
			for vi in vertices.size():
				var world_pos := vertices[vi] + chunk_center
				var d := world_pos.normalized()
				var lon := atan2(d.z, d.x)
				var lat := asin(clampf(d.y, -1.0, 1.0))
				var x_m := lon * data.radius
				var y_m := lat * data.radius
				gl_uvs[vi] = Vector2(x_m / GRASS_TILE_M - _gl_u_off, y_m / GRASS_TILE_M - _gl_v_off)
			var gl_arrays: Array = []
			gl_arrays.resize(Mesh.ARRAY_MAX)
			gl_arrays[Mesh.ARRAY_VERTEX]  = vertices
			gl_arrays[Mesh.ARRAY_NORMAL]  = normals
			gl_arrays[Mesh.ARRAY_TEX_UV]  = gl_uvs
			gl_arrays[Mesh.ARRAY_INDEX]   = meadow_indices
			var gl_surface_idx := mesh.get_surface_count()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, gl_arrays)
			mesh.surface_set_material(gl_surface_idx, gl_mat)

	# --- forest_ground: leaf-litter texture overlay on temperate forest ------
	# Same pattern as the meadow grass overlay — tiled lon/lat UVs on a shared
	# vertex buffer, drawn as an extra surface replacing the base terrain.
	if forest_ground_indices.size() > 0:
		var fg_mat: Material = data.get_forest_ground_material()
		if fg_mat:
			fg_mat = fg_mat.duplicate() as Material
			if fg_mat is BaseMaterial3D:
				(fg_mat as BaseMaterial3D).heightmap_enabled = false
				(fg_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
			var _fg_tile_m: float = ForestTemperateForestTerrain.TILE_M
			var _fg_cd := chunk_center.normalized()
			var _fg_clon := atan2(_fg_cd.z, _fg_cd.x)
			var _fg_clat := asin(clampf(_fg_cd.y, -1.0, 1.0))
			var _fg_u_off := floorf(_fg_clon * data.radius / _fg_tile_m)
			var _fg_v_off := floorf(_fg_clat * data.radius / _fg_tile_m)
			var fg_uvs := PackedVector2Array()
			fg_uvs.resize(vertices.size())
			for vi in vertices.size():
				var world_pos := vertices[vi] + chunk_center
				var d := world_pos.normalized()
				var lon := atan2(d.z, d.x)
				var lat := asin(clampf(d.y, -1.0, 1.0))
				var x_m := lon * data.radius
				var y_m := lat * data.radius
				fg_uvs[vi] = Vector2(x_m / _fg_tile_m - _fg_u_off, y_m / _fg_tile_m - _fg_v_off)
			var fg_arrays: Array = []
			fg_arrays.resize(Mesh.ARRAY_MAX)
			fg_arrays[Mesh.ARRAY_VERTEX]  = vertices
			fg_arrays[Mesh.ARRAY_NORMAL]  = normals
			fg_arrays[Mesh.ARRAY_TEX_UV]  = fg_uvs
			fg_arrays[Mesh.ARRAY_INDEX]   = forest_ground_indices
			var fg_surface_idx := mesh.get_surface_count()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, fg_arrays)
			mesh.surface_set_material(fg_surface_idx, fg_mat)

	# --- cliff: ORMMaterial3D overlay on steep cliff faces -------------------
	# Only triangles within the cliff biome whose face normal is nearly
	# vertical get this overlay.  Tiled UVs use the same lon/lat projection
	# as lunar ground / meadow.
	if cliff_indices.size() > 0:
		var cl_mat: Material = data.get_cliff_material()
		if cl_mat:
			cl_mat = cl_mat.duplicate() as Material
			if cl_mat is BaseMaterial3D:
				(cl_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
				# Disable heightmap/parallax — deep parallax displaces pixels
				# independently per chunk, creating visible seams at boundaries.
				(cl_mat as BaseMaterial3D).heightmap_enabled = false
			var _cl_tile_m := RockyLandformCliffTerrain.TILE_M
			var _cl_cd := chunk_center.normalized()
			var _cl_clon := atan2(_cl_cd.z, _cl_cd.x)
			var _cl_clat := asin(clampf(_cl_cd.y, -1.0, 1.0))
			var _cl_u_off := floorf(_cl_clon * data.radius / _cl_tile_m)
			var _cl_v_off := floorf(_cl_clat * data.radius / _cl_tile_m)
			var cl_uvs := PackedVector2Array()
			cl_uvs.resize(vertices.size())
			for vi in vertices.size():
				var world_pos := vertices[vi] + chunk_center
				var d := world_pos.normalized()
				var lon := atan2(d.z, d.x)
				var lat := asin(clampf(d.y, -1.0, 1.0))
				var x_m := lon * data.radius
				var y_m := lat * data.radius
				cl_uvs[vi] = Vector2(x_m / _cl_tile_m - _cl_u_off, y_m / _cl_tile_m - _cl_v_off)
			var cl_arrays: Array = []
			cl_arrays.resize(Mesh.ARRAY_MAX)
			cl_arrays[Mesh.ARRAY_VERTEX]  = vertices
			cl_arrays[Mesh.ARRAY_NORMAL]  = normals
			cl_arrays[Mesh.ARRAY_TEX_UV]  = cl_uvs
			cl_arrays[Mesh.ARRAY_INDEX]   = cliff_indices
			var cl_surface_idx := mesh.get_surface_count()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cl_arrays)
			mesh.surface_set_material(cl_surface_idx, cl_mat)

	# --- road: biome-adaptive texture overlay on terrain --------------------
	# Roads are independent strip meshes extruded from centerline data,
	# not derived from terrain grid quads.  This gives pixel-accurate width
	# regardless of terrain mesh resolution.
	#
	# UVs are flow-aligned (U = along road, V = across road) so the
	# texture follows the road direction.
	#
	# Material selection: highways/roads → fixed asphalt; paths/trails →
	# biome-adaptive (e.g. path_grass in meadow, path_dirt in forest).
	if has_road_overlap and rq:
		var _rd_m_per_deg := data.radius * PI / 180.0
		var _rd_cbb: Array[Vector2]
		if hp_mode:
			_rd_cbb = _cbb  # Reuse HEALPix bbox computed earlier.
		else:
			_rd_cbb = BiomeQuery._chunk_lonlat_bbox(
				face, u_min, u_max, v_min, v_max)
		var _rd_cbb_min: Vector2 = _rd_cbb[0]
		var _rd_cbb_max: Vector2 = _rd_cbb[1]
		if hp_mode:
			print("[ROAD DBG] chunk hp_n%d_p%d cbb_ll=(%.8f,%.8f)→(%.8f,%.8f)" % [
				hp_nside, hp_ipix,
				_rd_cbb_min.x, _rd_cbb_min.y, _rd_cbb_max.x, _rd_cbb_max.y])
		else:
			print("[ROAD DBG] chunk face=%d u=[%.8f,%.8f] v=[%.8f,%.8f] cbb_ll=(%.8f,%.8f)→(%.8f,%.8f)" % [
				face, u_min, u_max, v_min, v_max,
				_rd_cbb_min.x, _rd_cbb_min.y, _rd_cbb_max.x, _rd_cbb_max.y])

		# Group strip geometry by material path.
		var road_groups: Dictionary = {}

		for _rd_zone in rq.get_zones_for_region(_rd_cbb_min, _rd_cbb_max):
			if not RoadTerrain.is_road_zone(_rd_zone):
				print("[ROAD DBG]   zone skipped: not a road zone")
				continue
			if not BiomeQuery._aabb_overlap(
					_rd_cbb_min, _rd_cbb_max,
					_rd_zone.bbox_min, _rd_zone.bbox_max):
				print("[ROAD DBG]   zone skipped: AABB no overlap. zone_bb=(%.8f,%.8f)→(%.8f,%.8f)" % [
					_rd_zone.bbox_min.x, _rd_zone.bbox_min.y, _rd_zone.bbox_max.x, _rd_zone.bbox_max.y])
				continue
			print("[ROAD DBG]   zone PASSED AABB: rt=%s" % RoadTerrain.get_road_type(_rd_zone))

			RoadTerrain.prepare_zone(_rd_zone, data.radius)
			var _rd_rt := RoadTerrain.get_road_type(_rd_zone)
			var _rd_hw_m: float = RoadTerrain.HALF_WIDTH_M.get(_rd_rt, 0.5)
			var _rd_hw_deg: float = _rd_hw_m / _rd_m_per_deg
			var _rd_tile_m: float = RoadTerrain.get_tile_size(_rd_rt)
			var _rd_cl: PackedVector2Array = _rd_zone.get(
				"centerline", PackedVector2Array())
			if _rd_cl.size() < 2:
				continue

			var _rd_mid_ll := (_rd_cl[0] + _rd_cl[_rd_cl.size() - 1]) * 0.5
			var _rd_biome_type := ""
			if not _pz_zones.is_empty():
				var _rd_mid_lon := deg_to_rad(_rd_mid_ll.x)
				var _rd_mid_lat := deg_to_rad(_rd_mid_ll.y)
				var _rd_mid_dir := Vector3(
					cos(_rd_mid_lat) * cos(_rd_mid_lon),
					sin(_rd_mid_lat),
					cos(_rd_mid_lat) * sin(_rd_mid_lon))
				var _rd_mid_zones := _query_zones_at_direction(_rd_mid_dir, _pz_zones)
				if not _rd_mid_zones.is_empty():
					var _rd_mid_bd := data.get_biome_by_type(
						_rd_mid_zones[0].get("biome_type", ""))
					if _rd_mid_bd:
						_rd_biome_type = _rd_mid_bd.biome_type

			var _mat_path := RoadTerrain.get_material_path(
				_rd_rt, _rd_biome_type)

			if not road_groups.has(_mat_path):
				road_groups[_mat_path] = {
					"verts": PackedVector3Array(),
					"norms": PackedVector3Array(),
					"uvs": PackedVector2Array(),
					"indices": PackedInt32Array(),
					"tile_m": _rd_tile_m,
				}
			var grp: Dictionary = road_groups[_mat_path]
			var grp_verts: PackedVector3Array = grp["verts"]
			var grp_norms: PackedVector3Array = grp["norms"]
			var grp_uvs: PackedVector2Array = grp["uvs"]
			var grp_indices: PackedInt32Array = grp["indices"]
			var _strip_base: int = grp_verts.size()

			var along_m := 0.0
			# Use chunk degree span (not cube-face UV span) so subdivision
			# matches the centerline's coordinate system (degrees).
			var _max_seg_deg := maxf(
				_rd_cbb_max.x - _rd_cbb_min.x,
				_rd_cbb_max.y - _rd_cbb_min.y) / float(res) * 0.5

			for _seg_i in _rd_cl.size() - 1:
				var p0 := _rd_cl[_seg_i]
				var p1 := _rd_cl[_seg_i + 1]
				var seg_dir := p1 - p0
				var seg_len_deg := seg_dir.length()
				if seg_len_deg < 1e-12:
					along_m += seg_len_deg * _rd_m_per_deg
					continue

				var perp := Vector2(-seg_dir.y, seg_dir.x).normalized()
				var n_sub := maxi(1, ceili(seg_len_deg / _max_seg_deg))

				for _sub_j in n_sub + 1:
					if _sub_j == n_sub and _seg_i < _rd_cl.size() - 2:
						continue
					var frac := float(_sub_j) / float(n_sub)
					var pt := p0 + seg_dir * frac
					var along_here := along_m + seg_len_deg * frac * _rd_m_per_deg
					var pt_l := pt + perp * _rd_hw_deg
					var pt_r := pt - perp * _rd_hw_deg

					for _side_ll in [pt_l, pt_r]:
						var _lon_r := deg_to_rad(_side_ll.x)
						var _lat_r := deg_to_rad(_side_ll.y)
						var _dir := Vector3(
							cos(_lat_r) * cos(_lon_r),
							sin(_lat_r),
							cos(_lat_r) * sin(_lon_r))
						var _h: float
						if hp_mode:
							_h = data.sample_height_for_direction(_dir, _export_ipix)
						else:
							var _fuv := PlanetData.sphere_to_cube(_dir)
							_h = data.sample_height_for_chunk(
								_fuv["face"], _fuv["u"], _fuv["v"],
								u_min, u_max, v_min, v_max)
						var _pos := _dir * (data.radius + _h + RoadTerrain.SURFACE_OFFSET)
						grp_verts.append(_world_to_local(_pos, cc_f32, _wp_f32))
						grp_norms.append(_dir)

					var _u_along := along_here / _rd_tile_m
					grp_uvs.append(Vector2(_u_along, _rd_hw_m / _rd_tile_m))
					grp_uvs.append(Vector2(_u_along, -_rd_hw_m / _rd_tile_m))

				along_m += seg_len_deg * _rd_m_per_deg

			# Build quad-strip indices: pairs [L0,R0, L1,R1, ...].
			var _pair_count: int = (grp_verts.size() - _strip_base) / 2
			print("[ROAD DBG]   strip: %d verts, %d pairs, base=%d, mat=%s, biome=%s" % [
				grp_verts.size() - _strip_base, _pair_count, _strip_base, _mat_path, _rd_biome_type])
			for _pi in _pair_count - 1:
				var _li := _strip_base + _pi * 2      # left  current
				var _ri := _li + 1                     # right current
				var _ln := _li + 2                     # left  next
				var _rn := _li + 3                     # right next
				grp_indices.append(_li)
				grp_indices.append(_ln)
				grp_indices.append(_ri)
				grp_indices.append(_ri)
				grp_indices.append(_ln)
				grp_indices.append(_rn)

			# Write modified packed arrays back to the dictionary.
			# PackedArray types use copy-on-write so the dictionary must
			# be updated explicitly after local modifications.
			grp["verts"] = grp_verts
			grp["norms"] = grp_norms
			grp["uvs"] = grp_uvs
			grp["indices"] = grp_indices

		# Offset flow-aligned UVs per group so values stay near zero
		# (prevents GPU float32 precision artifacts on large planets).
		for _grp_key in road_groups:
			var _off_uvs: PackedVector2Array = road_groups[_grp_key]["uvs"]
			if _off_uvs.size() == 0:
				continue
			var _min_u := _off_uvs[0].x
			var _min_v := _off_uvs[0].y
			for _ui in range(1, _off_uvs.size()):
				if _off_uvs[_ui].x < _min_u: _min_u = _off_uvs[_ui].x
				if _off_uvs[_ui].y < _min_v: _min_v = _off_uvs[_ui].y
			var _uv_off := Vector2(floorf(_min_u), floorf(_min_v))
			for _ui in _off_uvs.size():
				_off_uvs[_ui] -= _uv_off
			road_groups[_grp_key]["uvs"] = _off_uvs

		# Emit one surface per material group using SurfaceTool for
		# tangent generation (needed by normal-mapped road materials).
		for mat_path in road_groups:
			var grp: Dictionary = road_groups[mat_path]
			var rv: PackedVector3Array = grp["verts"]
			var rn: PackedVector3Array = grp["norms"]
			var ru: PackedVector2Array = grp["uvs"]
			var ri: PackedInt32Array = grp["indices"]
			if rv.size() == 0:
				print("[ROAD DBG] emit: %s — 0 verts, skipping" % mat_path)
				continue
			print("[ROAD DBG] emit: %s — %d verts, %d idx, v[0]=%s v[1]=%s" % [
				mat_path, rv.size(), ri.size(),
				rv[0], rv[mini(1, rv.size() - 1)]])
			# Load the road material.
			var rd_mat: Material = null
			if data._road_material_cache.has(mat_path):
				rd_mat = data._road_material_cache[mat_path]
			elif ResourceLoader.exists(mat_path):
				var loaded = ResourceLoader.load(mat_path)
				if loaded is Material:
					data._road_material_cache[mat_path] = loaded
					rd_mat = loaded
			if rd_mat == null:
				print("[ROAD DBG]   mat NULL, skipping surface")
				continue
			rd_mat = rd_mat.duplicate() as Material
			if rd_mat is BaseMaterial3D:
				var bm := rd_mat as BaseMaterial3D
				bm.render_priority = 2
				# Disable deep parallax — auto-generated tangents are
				# sufficient for normal mapping but parallax on a flat
				# overlay adds cost without visual benefit.
				bm.heightmap_enabled = false
				# Render both faces to avoid winding-order issues.
				bm.cull_mode = BaseMaterial3D.CULL_DISABLED
			# Build surface via SurfaceTool so tangents are generated
			# (required for correct normal mapping on road materials).
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			for _vi in rv.size():
				st.set_normal(rn[_vi])
				st.set_uv(ru[_vi])
				st.add_vertex(rv[_vi])
			for _idx in ri:
				st.add_index(_idx)
			st.generate_tangents()
			var rd_si := mesh.get_surface_count()
			st.commit(mesh)
			mesh.surface_set_material(rd_si, rd_mat)

	# --- lava_river: hot lava surface sitting ON TOP of the depression ------
	# Like the river water overlay, the lava surface is built as a separate
	# mesh with its own vertices placed at the original (pre-depression)
	# terrain height.  This makes the lava fill the channel like a liquid,
	# sitting at the landscape level instead of following the carved floor.
	#
	# UVs are FLOW-ALIGNED: U runs along the centerline direction and
	# V runs perpendicular to it.  The texture's horizontal axis (U) is
	# more continuous, matching the natural flow of the lava texture.
	if has_lava_river_overlap:
		var lr_mat: Material = data.get_lava_river_material()
		if lr_mat:
			lr_mat = lr_mat.duplicate() as Material
			lr_mat.render_priority = 1
			if lr_mat is BaseMaterial3D:
				(lr_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED

			var lr_verts := PackedVector3Array()
			var lr_norms := PackedVector3Array()
			var lr_uvs := PackedVector2Array()
			var lr_indices := PackedInt32Array()
			var lr_remap: Dictionary = {}

			# Tile size for flow-aligned UVs — from the terrain module.
			var _lr_tile_m: float = VolcanicGeothermalLavaRiverTerrain.TILE_M

			for yi in res:
				for xi in res:
					var i00 := yi * (res + 1) + xi
					var i10 := i00 + 1
					var i01 := i00 + (res + 1)
					var i11 := i01 + 1
					# Include quad if ANY corner is a lava_river vertex.
					if is_lava_river_vertex[i00] == 0 \
							and is_lava_river_vertex[i10] == 0 \
							and is_lava_river_vertex[i01] == 0 \
							and is_lava_river_vertex[i11] == 0:
						continue
					for orig_idx in [i00, i10, i01, i11]:
						if not lr_remap.has(orig_idx):
							var new_idx: int = lr_verts.size()
							lr_remap[orig_idx] = new_idx
							var planet_pos := vertices[orig_idx] + chunk_center
							var ldir := planet_pos.normalized()
							# Use the original (pre-depression) height for lava
							# vertices, terrain height for boundary vertices.
							var h: float
							if is_lava_river_vertex[orig_idx] == 1:
								h = lava_river_original_height[orig_idx]
							else:
								h = planet_pos.length() - data.radius
							lr_verts.append(_world_to_local(ldir * (data.radius + h - VolcanicGeothermalLavaRiverTerrain.SURFACE_OFFSET), cc_f32, _wp_f32))
							lr_norms.append(ldir)
							# Flow-aligned UVs: U = along flow, V = across.
							# Pre-computed during vertex flagging in metres;
							# boundary verts (flag==0) get lon/lat fallback.
							var fuv: Vector2
							if is_lava_river_vertex[orig_idx] == 1:
								fuv = lava_river_flow_uv[orig_idx]
							else:
								# Boundary vertex: approximate with lon/lat.
								var lon := atan2(ldir.z, ldir.x)
								var lat := asin(clampf(ldir.y, -1.0, 1.0))
								fuv = Vector2(lon * data.radius, lat * data.radius)
							lr_uvs.append(fuv / _lr_tile_m)
					# Two triangles for this quad.
					lr_indices.append(lr_remap[i00])
					lr_indices.append(lr_remap[i01])
					lr_indices.append(lr_remap[i10])
					lr_indices.append(lr_remap[i10])
					lr_indices.append(lr_remap[i01])
					lr_indices.append(lr_remap[i11])

			if lr_verts.size() > 0:
				var lr_arrays: Array = []
				lr_arrays.resize(Mesh.ARRAY_MAX)
				lr_arrays[Mesh.ARRAY_VERTEX]  = lr_verts
				lr_arrays[Mesh.ARRAY_NORMAL]  = lr_norms
				lr_arrays[Mesh.ARRAY_TEX_UV]  = lr_uvs
				lr_arrays[Mesh.ARRAY_INDEX]   = lr_indices
				var lr_surface_idx := mesh.get_surface_count()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, lr_arrays)
				mesh.surface_set_material(lr_surface_idx, lr_mat)

	# --- dry_river_bed: pebble texture overlay on the carved riverbed floor ---
	# The pebble material sits directly ON the depressed terrain surface
	# (unlike lava river which sits at the pre-depression height).
	# UVs are FLOW-ALIGNED — U along the centerline, V across — so the
	# riverbed pebble texture follows the natural channel direction.
	if has_dry_river_bed_overlap:
		var drb_mat: Material = data.get_riverbed_material()
		if drb_mat:
			drb_mat = drb_mat.duplicate() as Material
			drb_mat.render_priority = 1
			if drb_mat is BaseMaterial3D:
				(drb_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
				# Disable heightmap deep parallax per-chunk — seams at chunk
				# boundaries from independent POM ray-marching.
				(drb_mat as BaseMaterial3D).heightmap_enabled = false

			var drb_verts := PackedVector3Array()
			var drb_norms := PackedVector3Array()
			var drb_uvs := PackedVector2Array()
			var drb_indices := PackedInt32Array()
			var drb_remap: Dictionary = {}
			var _drb_tile_m: float = ArideDesertDryRiverBedTerrain.TILE_M

			for yi in res:
				for xi in res:
					var i00 := yi * (res + 1) + xi
					var i10 := i00 + 1
					var i01 := i00 + (res + 1)
					var i11 := i01 + 1
					# Include quad if ANY corner is a dry riverbed vertex.
					if is_dry_river_bed_vertex[i00] == 0 \
							and is_dry_river_bed_vertex[i10] == 0 \
							and is_dry_river_bed_vertex[i01] == 0 \
							and is_dry_river_bed_vertex[i11] == 0:
						continue
					for orig_idx in [i00, i10, i01, i11]:
						if not drb_remap.has(orig_idx):
							var new_idx: int = drb_verts.size()
							drb_remap[orig_idx] = new_idx
							drb_verts.append(vertices[orig_idx])
							drb_norms.append(normals[orig_idx])
							var fuv: Vector2
							if is_dry_river_bed_vertex[orig_idx] == 1:
								fuv = dry_river_bed_flow_uv[orig_idx]
							else:
								# Boundary vertex — approximate with lon/lat projection.
								var _planet_pos := vertices[orig_idx] + chunk_center
								var _d := _planet_pos.normalized()
								var _lon := atan2(_d.z, _d.x)
								var _lat := asin(clampf(_d.y, -1.0, 1.0))
								fuv = Vector2(_lon * data.radius, _lat * data.radius)
							drb_uvs.append(fuv / _drb_tile_m)
					# Two triangles for this quad.
					drb_indices.append(drb_remap[i00])
					drb_indices.append(drb_remap[i01])
					drb_indices.append(drb_remap[i10])
					drb_indices.append(drb_remap[i10])
					drb_indices.append(drb_remap[i01])
					drb_indices.append(drb_remap[i11])

			if drb_verts.size() > 0:
				var drb_arrays: Array = []
				drb_arrays.resize(Mesh.ARRAY_MAX)
				drb_arrays[Mesh.ARRAY_VERTEX]  = drb_verts
				drb_arrays[Mesh.ARRAY_NORMAL]  = drb_norms
				drb_arrays[Mesh.ARRAY_TEX_UV]  = drb_uvs
				drb_arrays[Mesh.ARRAY_INDEX]   = drb_indices
				var drb_surface_idx := mesh.get_surface_count()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, drb_arrays)
				mesh.surface_set_material(drb_surface_idx, drb_mat)

	# --- per-chunk water overlay --------------------------------------------
	# If this chunk overlaps a liquid zone, build a mesh surface whose
	# vertices sit at the original terrain height + WATER_OFFSET.  This makes
	# the water follow the landscape contour regardless of heightmap values.
	if has_liquid_overlap:
		var liquid_mat: Material = data.get_liquid_material()
		if liquid_mat:
			# Duplicate so we can set per-planet shader parameters.
			liquid_mat = liquid_mat.duplicate() as Material

			# Collect quads that have at least one liquid vertex.
			var w_verts := PackedVector3Array()
			var w_normals := PackedVector3Array()
			var w_uvs := PackedVector2Array()
			var w_indices := PackedInt32Array()
			# Map from original vertex index → water vertex index.
			var remap: Dictionary = {}

			for yi in res:
				for xi in res:
					var i00 := yi * (res + 1) + xi
					var i10 := i00 + 1
					var i01 := i00 + (res + 1)
					var i11 := i01 + 1
					# Include the quad if ANY corner is liquid.
					if is_liquid_vertex[i00] == 0 and is_liquid_vertex[i10] == 0 \
							and is_liquid_vertex[i01] == 0 and is_liquid_vertex[i11] == 0:
						continue
					# Ensure all 4 corners are in the water vertex list.
					for orig_idx in [i00, i10, i01, i11]:
						if not remap.has(orig_idx):
							var new_idx: int = w_verts.size()
							remap[orig_idx] = new_idx
							var planet_pos := vertices[orig_idx] + chunk_center
							var dir := planet_pos.normalized()
							# Place water at original terrain height + small
							# offset so it sits right at the landscape level.
							var h: float
							if is_liquid_vertex[orig_idx] == 1:
								h = original_height[orig_idx]
							elif orig_idx < original_height.size():
								h = original_height[orig_idx]
							else:
								h = 0.0
							# Non-liquid corners of boundary quads: use the
							# terrain height from the vertex directly.
							if is_liquid_vertex[orig_idx] == 0:
								h = planet_pos.length() - data.radius
							w_verts.append(_world_to_local(dir * (data.radius + h + WATER_OFFSET), cc_f32, _wp_f32))
							w_normals.append(dir)
							w_uvs.append(uvs[orig_idx])
					# Two triangles for this quad.
					w_indices.append(remap[i00])
					w_indices.append(remap[i01])
					w_indices.append(remap[i10])
					w_indices.append(remap[i10])
					w_indices.append(remap[i01])
					w_indices.append(remap[i11])

			if w_verts.size() > 0:
				# Set shader params using average water radius for wave calc.
				var avg_water_r: float = 0.0
				for wv in w_verts:
					avg_water_r += (wv + chunk_center).length()
				avg_water_r /= float(w_verts.size())
				if liquid_mat is ShaderMaterial:
					var sm := liquid_mat as ShaderMaterial
					sm.set_shader_parameter("planet_radius", avg_water_r)
					sm.set_shader_parameter("water_level_offset", 0.0)

				var w_arrays: Array = []
				w_arrays.resize(Mesh.ARRAY_MAX)
				w_arrays[Mesh.ARRAY_VERTEX] = w_verts
				w_arrays[Mesh.ARRAY_NORMAL] = w_normals
				w_arrays[Mesh.ARRAY_TEX_UV] = w_uvs
				w_arrays[Mesh.ARRAY_INDEX]  = w_indices
				var liquid_surface_idx := mesh.get_surface_count()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, w_arrays)
				mesh.surface_set_material(liquid_surface_idx, liquid_mat)

	# --- shallow water overlay (swamp, bog, marsh) --------------------------
	# Thin translucent water sheet at terrain level — no depression.
	# Placed as the next available surface after terrain (+ liquid if present).
	const SHALLOW_WATER_OFFSET := 0.3  # metres above terrain
	if has_shallow_water_overlap:
		var sw_mat: Material = data.get_shallow_water_material()
		if sw_mat:
			sw_mat = sw_mat.duplicate() as Material

			var sw_verts := PackedVector3Array()
			var sw_normals := PackedVector3Array()
			var sw_uvs := PackedVector2Array()
			var sw_colors := PackedColorArray()  # .r = edge_fade (0=edge, 1=interior)
			var sw_indices := PackedInt32Array()
			var sw_remap: Dictionary = {}
			# Fade band in metres — over this distance alpha ramps from 0 to full.
			var sw_fade_m := 20.0
			var sw_m_per_deg := data.radius * PI / 180.0

			for yi in res:
				for xi in res:
					var i00 := yi * (res + 1) + xi
					var i10 := i00 + 1
					var i01 := i00 + (res + 1)
					var i11 := i01 + 1
					# Include quad if ANY corner is shallow_water.
					if is_shallow_water_vertex[i00] == 0 \
							and is_shallow_water_vertex[i10] == 0 \
							and is_shallow_water_vertex[i01] == 0 \
							and is_shallow_water_vertex[i11] == 0:
						continue
					for orig_idx in [i00, i10, i01, i11]:
						if not sw_remap.has(orig_idx):
							var new_idx: int = sw_verts.size()
							sw_remap[orig_idx] = new_idx
							var planet_pos := vertices[orig_idx] + chunk_center
							var sdir := planet_pos.normalized()
							var h: float = planet_pos.length() - data.radius
							sw_verts.append(_world_to_local(sdir * (data.radius + h + SHALLOW_WATER_OFFSET), cc_f32, _wp_f32))
							sw_normals.append(sdir)
							sw_uvs.append(uvs[orig_idx])
							# Edge fade: distance to polygon boundary → 0..1 ramp.
							var edge_f := 1.0
							if is_shallow_water_vertex[orig_idx] == 1 and not _pz_zones.is_empty():
								var sw_lonlat := BiomeQuery._dir_to_lonlat(sdir)
								var sw_zones := _query_zones_at_direction(sdir, _pz_zones)
								for sw_z in sw_zones:
									var sw_bd := data.get_biome_by_type(sw_z.get("biome_type", ""))
									if sw_bd and sw_bd.has_shallow_water:
										var _sw_verts: Array = sw_z.get("vertices", [])
										if _sw_verts.size() >= 3:
											var _sw_poly := PackedVector2Array()
											for _sv in _sw_verts:
												_sw_poly.append(Vector2(_sv[0], _sv[1]))
											var d_deg := BiomeQuery._dist_to_polygon_edge(sw_lonlat, _sw_poly)
											var d_m := d_deg * sw_m_per_deg
											edge_f = clampf(d_m / sw_fade_m, 0.0, 1.0)
										elif sw_z.get("coverage", "") == "full":
											edge_f = 1.0
										break
							else:
								edge_f = 0.0  # non-shallow boundary vertex
							sw_colors.append(Color(edge_f, 0.0, 0.0, 1.0))
					sw_indices.append(sw_remap[i00])
					sw_indices.append(sw_remap[i01])
					sw_indices.append(sw_remap[i10])
					sw_indices.append(sw_remap[i10])
					sw_indices.append(sw_remap[i01])
					sw_indices.append(sw_remap[i11])

			if sw_verts.size() > 0:
				var avg_sw_r: float = 0.0
				for sv in sw_verts:
					avg_sw_r += (sv + chunk_center).length()
				avg_sw_r /= float(sw_verts.size())
				if sw_mat is ShaderMaterial:
					var sm := sw_mat as ShaderMaterial
					sm.set_shader_parameter("planet_radius", avg_sw_r)
					sm.set_shader_parameter("water_level_offset", 0.0)

				var sw_arrays: Array = []
				sw_arrays.resize(Mesh.ARRAY_MAX)
				sw_arrays[Mesh.ARRAY_VERTEX] = sw_verts
				sw_arrays[Mesh.ARRAY_NORMAL] = sw_normals
				sw_arrays[Mesh.ARRAY_TEX_UV] = sw_uvs
				sw_arrays[Mesh.ARRAY_COLOR]  = sw_colors
				sw_arrays[Mesh.ARRAY_INDEX]  = sw_indices
				var sw_surface_idx := mesh.get_surface_count()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sw_arrays)
				mesh.surface_set_material(sw_surface_idx, sw_mat)

	# --- river water overlay ------------------------------------------------
	# Flowing water surface for river biomes.  Built as a ribbon mesh that
	# follows the centerline geometry, giving smooth edges independent of
	# the terrain grid resolution.  Each cross-section has N_ACROSS+1
	# vertices with cross_t evenly spaced from 0 (center) to 1 (edge).
	# The ribbon is clipped to the chunk lon/lat bounding box to avoid
	# double-rendering across adjacent chunks.
	if has_river_overlap:
		var rw_mat: Material = data.get_river_material()
		if rw_mat:
			rw_mat = rw_mat.duplicate() as Material

			var rw_verts := PackedVector3Array()
			var rw_normals := PackedVector3Array()
			var rw_uvs := PackedVector2Array()
			var rw_colors := PackedColorArray()  # .r = cross_t, .g = along_t
			var rw_indices := PackedInt32Array()

			# Number of vertex pairs across the half-width (center to edge).
			# Full cross-section has 2*N_HALF+1 vertices (mirrored).
			const N_HALF := 4
			const N_ACROSS := 2 * N_HALF  # divisions across full width

			# Chunk bounding box in lon/lat for clipping (already computed).
			var _rw_bb_min: Vector2 = _cbb[0] if _cbb.size() >= 2 else Vector2(-180, -90)
			var _rw_bb_max: Vector2 = _cbb[1] if _cbb.size() >= 2 else Vector2(180, 90)

			var m_per_deg := data.radius * PI / 180.0

			for _rz in _river_zones:
				var cl: PackedVector2Array = _rz.get("centerline", PackedVector2Array())
				if cl.size() < 2:
					continue
				var cum: PackedFloat64Array = _rz.get("_cum_lengths", PackedFloat64Array())
				var total_len: float = _rz.get("_total_length", 0.0)
				if total_len <= 0.0:
					continue

				# Progressive width in metres.
				var ws_m: float = _rz.get("width_start_m", 0.0)
				var we_m: float = _rz.get("width_end_m", 0.0)
				if ws_m <= 0.0 and we_m <= 0.0:
					var w: float = _rz.get("width", 10.0)
					ws_m = w
					we_m = w
				var max_hw_m: float = maxf(ws_m, we_m) * 0.5

				# Along-river step: ~1/4 of average width, clamped to [2m, 30m].
				var avg_w := (ws_m + we_m) * 0.5
				var step_m: float = clampf(avg_w * 0.25, 2.0, 30.0)

				# Resample the centerline at uniform spacing + original vertices.
				# Each sample: Vector3(lon, lat, along_m).
				var samples: Array[Vector3] = []
				samples.append(Vector3(cl[0].x, cl[0].y, 0.0))
				var accum_m := 0.0
				var next_stop := step_m
				for si in cl.size() - 1:
					var a := cl[si]
					var b := cl[si + 1]
					var seg_len: float = cum[si + 1] - cum[si] if si + 1 < cum.size() else 0.0
					if seg_len <= 0.0:
						continue
					# Emit intermediate samples within this segment.
					while next_stop < cum[si + 1]:
						var frac := (next_stop - cum[si]) / seg_len
						var pt := a.lerp(b, frac)
						samples.append(Vector3(pt.x, pt.y, next_stop))
						next_stop += step_m
					# Always emit the segment endpoint.
					accum_m = cum[si + 1]
					# Avoid duplicate if very close to last sample.
					if samples.size() == 0 or (Vector2(samples[samples.size() - 1].x, samples[samples.size() - 1].y) - b).length() * m_per_deg > 0.5:
						samples.append(Vector3(b.x, b.y, accum_m))

				if samples.size() < 2:
					continue

				# Margin in degrees for chunk clipping (half-width + one step).
				var margin_deg := (max_hw_m + step_m) / m_per_deg

				# Build ribbon cross-sections.  Each row has (N_ACROSS + 1) verts.
				var row_size := N_ACROSS + 1  # verts per cross-section
				# prev_row_start tracks the vertex index of the previous
				# in-bounds row so we only connect consecutive rows with
				# triangles (a clipped-out sample creates a gap).
				var prev_row_start: int = -1

				for si in samples.size():
					var sp := samples[si]
					var s_lon: float = sp.x
					var s_lat: float = sp.y
					var s_along_m: float = sp.z

					# Clip: skip centerline points outside chunk bounds (with margin).
					if s_lon < _rw_bb_min.x - margin_deg or s_lon > _rw_bb_max.x + margin_deg:
						prev_row_start = -1
						continue
					if s_lat < _rw_bb_min.y - margin_deg or s_lat > _rw_bb_max.y + margin_deg:
						prev_row_start = -1
						continue

					# along_t: 0 at start, 1 at end.
					var along_t: float = clampf(s_along_m / total_len, 0.0, 1.0)
					# Half-width at this position (metres).
					var hw_m: float = lerpf(ws_m, we_m, along_t) * 0.5
					var hw_deg: float = hw_m / m_per_deg

					# Tangent direction (lon/lat space) for perpendicular computation.
					var tangent: Vector2
					if si == 0:
						tangent = Vector2(samples[1].x - sp.x, samples[1].y - sp.y)
					elif si == samples.size() - 1:
						var prev_sp := samples[si - 1]
						tangent = Vector2(sp.x - prev_sp.x, sp.y - prev_sp.y)
					else:
						var prev_sp := samples[si - 1]
						var next_sp := samples[si + 1]
						tangent = Vector2(next_sp.x - prev_sp.x, next_sp.y - prev_sp.y)
					if tangent.length_squared() < 1e-20:
						tangent = Vector2(1, 0)
					tangent = tangent.normalized()
					# Perpendicular (rotate 90° clockwise in lon/lat).
					var perp := Vector2(-tangent.y, tangent.x)

					var this_row_start: int = rw_verts.size()

					# Generate cross-section vertices: from left edge → center → right edge.
					for ci in row_size:
						# cross_frac: -1 (left edge) → 0 (center) → +1 (right edge)
						var cross_frac: float = -1.0 + 2.0 * float(ci) / float(N_ACROSS)
						var cross_t_val: float = absf(cross_frac)  # 0=center, 1=edge
						# Position offset in lon/lat.
						var offset := perp * (cross_frac * hw_deg)
						var v_lon: float = s_lon + offset.x
						var v_lat: float = s_lat + offset.y

						var rdir := HEALPix.lonlat2vec(v_lon, v_lat)
						var h: float = data.sample_height_for_direction(rdir)
						rw_verts.append(_world_to_local(
								rdir * (data.radius + h + MaritimeRiverRiverTerrain.WATER_OFFSET),
								cc_f32, _wp_f32))
						rw_normals.append(rdir)
						rw_uvs.append(PlanetData.direction_to_uv(rdir))
						rw_colors.append(Color(cross_t_val, along_t, 0.0, 1.0))

					# Connect to previous row if it was in-bounds (no gap).
					if prev_row_start >= 0:
						var r0 := prev_row_start
						var r1 := this_row_start
						for ci in N_ACROSS:
							rw_indices.append(r0 + ci)
							rw_indices.append(r1 + ci)
							rw_indices.append(r0 + ci + 1)
							rw_indices.append(r0 + ci + 1)
							rw_indices.append(r1 + ci)
							rw_indices.append(r1 + ci + 1)
					prev_row_start = this_row_start

			if rw_verts.size() > 0:
				var avg_rw_r: float = 0.0
				for rv in rw_verts:
					avg_rw_r += (rv + chunk_center).length()
				avg_rw_r /= float(rw_verts.size())

				if rw_mat is ShaderMaterial:
					var sm := rw_mat as ShaderMaterial
					sm.set_shader_parameter("planet_radius", avg_rw_r)
					sm.set_shader_parameter("water_level_offset", 0.0)
					# Set flow direction from the first river zone found.
					if not river_zone_for_flow.is_empty():
						var center_dir := chunk_center.normalized()
						if center_dir.length_squared() < 0.5:
							center_dir = Vector3.UP
						var center_lonlat := BiomeQuery._dir_to_lonlat(center_dir)
						var flow_vec := BiomeQuery.get_flow_vector(
								river_zone_for_flow, center_lonlat)
						sm.set_shader_parameter("flow_dir", flow_vec)

				var rw_arrays: Array = []
				rw_arrays.resize(Mesh.ARRAY_MAX)
				rw_arrays[Mesh.ARRAY_VERTEX] = rw_verts
				rw_arrays[Mesh.ARRAY_NORMAL] = rw_normals
				rw_arrays[Mesh.ARRAY_TEX_UV] = rw_uvs
				rw_arrays[Mesh.ARRAY_COLOR]  = rw_colors
				rw_arrays[Mesh.ARRAY_INDEX]  = rw_indices
				var rw_surface_idx := mesh.get_surface_count()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, rw_arrays)
				mesh.surface_set_material(rw_surface_idx, rw_mat)

	return mesh


## Generate a [ConcavePolygonShape3D] for server-side collision.
## Uses the same cube-sphere + heightmap projection at a (usually lower)
## resolution to keep collision cheap.
static func generate_collision_shape(
		data: PlanetData,
		face: int,
		u_min: float, u_max: float,
		v_min: float, v_max: float,
		resolution: int,
		hp_nside: int = 0,
		hp_ipix: int = -1) -> ConcavePolygonShape3D:

	var hp_mode := hp_nside > 0
	var res := resolution
	var u_step := (u_max - u_min) / float(res) if not hp_mode else 0.0
	var v_step := (v_max - v_min) / float(res) if not hp_mode else 0.0

	var grid_dirs: Array[PackedVector3Array] = []
	var _export_ipix: int = -1
	# Collision-grid vertex spacing (m) — feeds the crack LOD fade.  The server
	# collision grid is ~397 m/vertex, far coarser than a ~500 m crack, so the
	# fade zeroes the carve here (and skips the expensive Voronoi), which is what
	# keeps the server framerate up.  Cracks are carved only where the grid is
	# fine enough to actually represent them.
	var _col_crack_spacing := 0.0
	if hp_mode:
		grid_dirs = HEALPix.get_pixel_grid(hp_nside, hp_ipix, res)
		if res > 0:
			_col_crack_spacing = HEALPix.pixel_side_length(hp_nside, 1.0) \
					* data.radius / float(res)
		if hp_nside >= data.export_nside:
			_export_ipix = hp_ipix
			var _ns := hp_nside
			while _ns > data.export_nside:
				_export_ipix >>= 2
				_ns /= 2

	# ── Fetch recipe data for collision overlap detection ─────────
	var _col_pz_zones: Array = []
	var _col_lf_arr: Array = []
	var _col_rf_arr: Array = []
	var _col_cr_arr: Array = []
	if hp_mode:
		var _col_eipix := _export_ipix
		_col_pz_zones = data.get_chunk_populate_zones(_col_eipix)
		_col_lf_arr = data.get_chunk_linear_features(_col_eipix)
		_col_rf_arr = data.get_chunk_radial_features(_col_eipix)
		_col_cr_arr = data.get_chunk_craters(_col_eipix)

	var has_liquid_overlap := false
	var has_linear_overlap := false
	var has_point_overlap := false
	var has_crater_overlap := false
	var has_lava_river_overlap := false
	var has_cliff_overlap := false
	var has_river_overlap := false
	var _col_river_zones: Array[Dictionary] = []

	# Populate zones (polygon/point biomes).
	for _pz in _col_pz_zones:
		var _bt: String = _pz.get("biome_type", "")
		var _bd = data.get_biome_by_type(_bt)
		if _bd == null:
			continue
		if _bd.is_liquid and data.has_ocean:
			has_liquid_overlap = true
		if CaveTerrain.is_cave_biome(_bd) \
				or VolcanicGeothermalFumaroleTerrain.is_fumarole_biome(_bd) \
				or VolcanicGeothermalIceGeyserTerrain.matches_zone(_bd) \
				or VolcanicGeothermalMineralThermalSourceTerrain.matches_zone(_bd):
			has_point_overlap = true
		if SpatialCraterTerrain.is_crater_biome(_bd):
			has_crater_overlap = true
		if RockyLandformCliffTerrain.matches_zone(_bd):
			has_cliff_overlap = true

	# Linear features.
	for _lf in _col_lf_arr:
		var _lt: String = _lf.get("type", "")
		var _lcl: Array = _lf.get("centerline", [])
		if _lcl.size() < 2:
			continue
		if _lt == "maritime_river-river":
			has_river_overlap = true
			_col_river_zones.append(_lf)
		elif _lt == "volcanic_geothermal-lava_river":
			has_lava_river_overlap = true
		elif _lt == "rocky_landform-canyon" or _lt == "icy-ice_crevasse" \
				or _lt == "aride_desert-dry_river_bed" \
				or _lt == "rocky_landform-pressure_canyon":
			has_linear_overlap = true

	# Radial features.
	for _rf in _col_rf_arr:
		var _rt: String = _rf.get("type", "")
		if _rt == "volcanic_geothermal-active_volcano":
			has_point_overlap = true

	# Craters.
	if not _col_cr_arr.is_empty():
		has_crater_overlap = true

	# Pre-prepare river zones.
	if has_river_overlap:
		for _rz in _col_river_zones:
			var _rcl: Array = _rz.get("centerline", [])
			if _rcl.size() >= 2:
				MaritimeRiverRiverTerrain.prepare_zone(_rz, data.radius)

	# ── Recipe crater data (collision) ─────────────────────────────
	var _col_recipe_craters: Array = _col_cr_arr

	# ── Pre-query compact craters from recipe ──────────────────────
	var _col_compact_craters: Array = _col_cr_arr

	# Build vertex grid
	var grid: Array[Vector3] = []
	grid.resize((res + 1) * (res + 1))

	# Pre-compute face/xy/neighbors for the export pixel (constant per chunk).
	# Passed through to sample_height_* so they skip redundant nest2xy and
	# get_neighbors_nest calls (14M+ saved for a tarsis_1-sized prebake).
	var _hp_face: int = -1
	var _hp_xy: Vector2i = Vector2i(-1, -1)
	var _hp_neighbors = null
	if hp_mode and _export_ipix >= 0:
		@warning_ignore("integer_division")
		_hp_face = _export_ipix / (data.export_nside * data.export_nside)
		var _hp_local := _export_ipix % (data.export_nside * data.export_nside)
		_hp_xy = HEALPix.nest2xy(_hp_local)
		_hp_neighbors = HEALPix.get_neighbors_nest(data.export_nside, _export_ipix)

	for yi in res + 1:
		for xi in res + 1:
			var dir: Vector3
			var height: float
			if hp_mode:
				dir = grid_dirs[yi][xi]
				if xi == 0 or xi == res or yi == 0 or yi == res:
					height = data.sample_height_boundary(dir, _export_ipix,
							_hp_face, _hp_xy, _hp_neighbors)
				else:
					height = data.sample_height_for_direction(dir, _export_ipix,
							_hp_face, _hp_xy, _hp_neighbors)
			else:
				var u: float
				if xi == 0:
					u = u_min
				elif xi == res:
					u = u_max
				else:
					u = u_min + xi * u_step
				var v: float
				if yi == 0:
					v = v_min
				elif yi == res:
					v = v_max
				else:
					v = v_min + yi * v_step
				dir = PlanetData.cube_to_sphere(face, u, v)
				height = data.sample_height_for_chunk(
						face, u, v, u_min, u_max, v_min, v_max)
			# Depress liquid biome zones below the water surface.
			# Rivers are carved at runtime (recipe too coarse), then
			# non-river liquids get a flat depression.
			if has_river_overlap:
				var lonlat := BiomeQuery._dir_to_lonlat(dir)
				var best_t: float = 1.0
				var best_along: float = 0.0
				var best_rzone: Dictionary = {}
				for _rz in _col_river_zones:
					var _rcl: PackedVector2Array = _rz.get("centerline", PackedVector2Array())
					if _rcl.size() < 2:
						continue
					var cs := BiomeQuery.get_cross_section_t(_rz, lonlat)
					var t: float = cs.t
					if t < best_t:
						best_t = t
						best_along = cs.along_t
						best_rzone = _rz
				if best_t < 1.0 and not best_rzone.is_empty():
					var ws: float = best_rzone.get("width_start_m", 0.0)
					var we: float = best_rzone.get("width_end_m", 0.0)
					var width_here: float
					if ws > 0.0 or we > 0.0:
						width_here = lerpf(ws, we, best_along)
					else:
						width_here = best_rzone.get("width", 10.0)
					var zdepth: float = width_here * MaritimeRiverRiverTerrain.DEPTH_RATIO
					if zdepth < 0.5:
						zdepth = 0.5
					height -= zdepth * (1.0 - best_t * best_t)
				elif has_liquid_overlap:
					# Not inside a river — check populate zones for liquid.
					var _lq_zones := _query_zones_at_direction(dir, _col_pz_zones)
					for _lq_z in _lq_zones:
						var _lq_bd := data.get_biome_by_type(_lq_z.get("biome_type", ""))
						if _lq_bd and _lq_bd.is_liquid:
							height -= 10.0
							break
			elif has_liquid_overlap:
				var _lq_zones := _query_zones_at_direction(dir, _col_pz_zones)
				for _lq_z in _lq_zones:
					var _lq_bd := data.get_biome_by_type(_lq_z.get("biome_type", ""))
					if _lq_bd and _lq_bd.is_liquid:
						height -= 10.0
						break
			# Linear depression — iterate recipe linear features.
			if has_linear_overlap:
				var _lin_lonlat := BiomeQuery._dir_to_lonlat(dir)
				for _lin_z in _col_lf_arr:
					var _lin_type: String = _lin_z.get("type", "")
					if _lin_type == "volcanic_geothermal-lava_river" \
							or _lin_type == "maritime_river-river":
						continue
					var _lin_cl: PackedVector2Array = _lin_z.get("centerline", PackedVector2Array())
					if _lin_cl.size() < 2:
						continue
					var _lin_depth_m: float = RockyLandformCanyonTerrain.DEFAULT_DEPTH_M
					match _lin_type:
						"rocky_landform-canyon":
							RockyLandformCanyonTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = RockyLandformCanyonTerrain.DEFAULT_DEPTH_M
						"icy-ice_crevasse":
							IcyIceCrevasseTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = IcyIceCrevasseTerrain.DEFAULT_DEPTH_M
						"aride_desert-dry_river_bed":
							ArideDesertDryRiverBedTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = ArideDesertDryRiverBedTerrain.DEFAULT_DEPTH_M
						"rocky_landform-pressure_canyon":
							RockyLandformPressureCanyonTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = RockyLandformPressureCanyonTerrain.DEFAULT_DEPTH_M
						_:
							RockyLandformCanyonTerrain.prepare_zone(_lin_z, data.radius)
					var _lin_cs := BiomeQuery.get_cross_section_t(_lin_z, _lin_lonlat)
					var ct: float = _lin_cs.t
					if ct < 1.0:
						var cdepth: float = _lin_z.get("depth_override", 0.0)
						if cdepth <= 0.0:
							cdepth = _lin_depth_m
						var ct2 := ct * ct
						height -= cdepth * (1.0 - ct2 * ct2)
						break
			# Lava river depression — iterate recipe linear features.
			if has_lava_river_overlap:
				for _lr_z in _col_lf_arr:
					if _lr_z.get("type", "") != "volcanic_geothermal-lava_river":
						continue
					var _lr_cl: PackedVector2Array = _lr_z.get("centerline", PackedVector2Array())
					if _lr_cl.size() < 2:
						continue
					VolcanicGeothermalLavaRiverTerrain.prepare_zone(_lr_z, data.radius)
					var lr_ll := BiomeQuery._dir_to_lonlat(dir)
					var _lr_cs2 := BiomeQuery.get_cross_section_t(_lr_z, lr_ll)
					var lr_ct: float = _lr_cs2.t
					if lr_ct < 1.0:
						var lr_dp: float = _lr_z.get("depth_override", 0.0)
						if lr_dp <= 0.0:
							lr_dp = VolcanicGeothermalLavaRiverTerrain.DEFAULT_DEPTH_M
						var lr_t2 := lr_ct * lr_ct
						height -= lr_dp * (1.0 - lr_t2 * lr_t2)
					break
			# Point depression — query populate zones for point biomes.
			var _is_hole_vertex := false
			if has_point_overlap:
				var _pt_zones := _query_zones_at_direction(dir, _col_pz_zones)
				for pz in _pt_zones:
					var pbd := data.get_biome_by_type(pz.get("biome_type", ""))
					if pbd == null:
						continue
					var _pt_radius: float = 0.0
					var _pt_depth: float = 0.0
					var _pt_hole_radius: float = 0.0
					var _pt_has_hole := false
					if CaveTerrain.is_cave_biome(pbd):
						_pt_radius = CaveTerrain.ENTRANCE_RADIUS_M
						_pt_depth = CaveTerrain.ENTRANCE_DEPTH_M
						_pt_hole_radius = CaveTerrain.HOLE_RADIUS_M
						_pt_has_hole = true
					elif VolcanicGeothermalFumaroleTerrain.matches_zone(pbd):
						_pt_radius = VolcanicGeothermalFumaroleTerrain.DEPRESSION_RADIUS_M
						_pt_depth = VolcanicGeothermalFumaroleTerrain.DEPRESSION_DEPTH_M
					elif VolcanicGeothermalIceGeyserTerrain.matches_zone(pbd):
						_pt_radius = VolcanicGeothermalIceGeyserTerrain.DEPRESSION_RADIUS_M
						_pt_depth = VolcanicGeothermalIceGeyserTerrain.DEPRESSION_DEPTH_M
					elif VolcanicGeothermalMineralThermalSourceTerrain.matches_zone(pbd):
						_pt_radius = VolcanicGeothermalMineralThermalSourceTerrain.DEPRESSION_RADIUS_M
						_pt_depth = VolcanicGeothermalMineralThermalSourceTerrain.DEPRESSION_DEPTH_M
					if _pt_radius > 0.0:
						var ccentroid := Vector2.ZERO
						var _pz_cov: String = pz.get("coverage", "")
						var _has_cen := false
						if _pz_cov == "point":
							ccentroid = Vector2(pz.get("lon", 0.0), pz.get("lat", 0.0))
							_has_cen = true
						else:
							var _pzverts: Array = pz.get("vertices", [])
							if _pzverts.size() >= 3:
								for _pvt in _pzverts:
									ccentroid += Vector2(_pvt[0], _pvt[1])
								ccentroid /= float(_pzverts.size())
								_has_cen = true
						if _has_cen:
							var clonlat := BiomeQuery._dir_to_lonlat(dir)
							var cm_per_deg := data.radius * PI / 180.0
							var cdist_m := (clonlat - ccentroid).length() * cm_per_deg
							if cdist_m < _pt_radius:
								if _pt_has_hole and cdist_m < _pt_hole_radius:
									var hole_dir := CaveTerrain.lonlat_to_dir(ccentroid)
									grid[yi * (res + 1) + xi] = hole_dir * (data.radius + height - _pt_depth)
									_is_hole_vertex = true
									break
								else:
									var tc: float
									if _pt_has_hole:
										tc = (cdist_m - _pt_hole_radius) / (_pt_radius - _pt_hole_radius)
									else:
										tc = cdist_m / _pt_radius
									height -= _pt_depth * (1.0 - tc * tc)
					break
			# ── Recipe crater displacement (collision) ─────────────
			if not _col_recipe_craters.is_empty():
				height += SpatialCraterTerrain.apply_craters(
					dir, _col_recipe_craters, data.radius)

			# ── Cliff displacement (collision) ─────────────────────
			if has_cliff_overlap:
				var _cl_zones := _query_zones_at_direction(dir, _col_pz_zones)
				for _clz in _cl_zones:
					var _clbd := data.get_biome_by_type(_clz.get("biome_type", ""))
					if _clbd and RockyLandformCliffTerrain.matches_zone(_clbd):
						var _cl_verts: Array = _clz.get("vertices", [])
						if _cl_verts.size() >= 3:
							var _cl_poly := PackedVector2Array()
							for _cv in _cl_verts:
								_cl_poly.append(Vector2(_cv[0], _cv[1]))
							var _cl_ll := BiomeQuery._dir_to_lonlat(dir)
							var _cl_mpd := data.radius * PI / 180.0
							var _cl_dist := BiomeQuery._dist_to_polygon_edge(_cl_ll, _cl_poly) * _cl_mpd
							var _cl_drop: float = _clz.get("depth", 0.0)
							if _cl_drop <= 0.0:
								_cl_drop = RockyLandformCliffTerrain.DROP_M
							height -= RockyLandformCliffTerrain.height_offset(_cl_dist, _cl_drop)
						break

			# ── Corundum crack network (collision) ─────────────────
			# Same pure crack_offset() and params as the visual mesh, with the
			# same LOD fade keyed on this grid's spacing — so where the collision
			# grid is fine enough it matches the client, and where it's too coarse
			# it fades to flat (and skips the Voronoi → server stays fast).
			if data.corundum_override_whole_planet:
				height += ArideDesertCorundumPlateauTerrain.crack_offset(
					dir, data.radius, data.crack_spacing_m,
					data.crack_width_m, data.crack_depth_m, _col_crack_spacing)

			# ── Write final vertex position ────────────────────────
			if not _is_hole_vertex:
				grid[yi * (res + 1) + xi] = dir * (data.radius + height)

	# Build triangle face array (3 vertices per triangle, packed sequentially).
	# Rebase vertices onto a chunk-local origin BEFORE packing into the
	# float32 PackedVector3Array.  At absolute planet scale (~6,000,000 m)
	# float32 has ~0.5 m ULP, which quantises the collision triangles and
	# displaces them from the client visual mesh — the mesh is likewise built
	# relative to this same snapped origin.  grid[] holds double-precision
	# Vector3s, so the subtraction is exact and only the small local offset is
	# stored as float32.  The caller offsets the CollisionShape3D by col_origin
	# in double precision (see PlanetTerrain._chunk_collision_origin).
	var col_origin := snap_to_f32(HEALPix.pix2vec_nest(hp_nside, hp_ipix) * data.radius) \
			if hp_mode else Vector3.ZERO
	var faces := PackedVector3Array()
	faces.resize(res * res * 6)
	var fi := 0
	for yi in res:
		for xi in res:
			var i := yi * (res + 1) + xi
			faces[fi]     = grid[i]           - col_origin
			faces[fi + 1] = grid[i + res + 1] - col_origin
			faces[fi + 2] = grid[i + 1]       - col_origin
			faces[fi + 3] = grid[i + 1]       - col_origin
			faces[fi + 4] = grid[i + res + 1] - col_origin
			faces[fi + 5] = grid[i + res + 2] - col_origin
			fi += 6

	var shape := ConcavePolygonShape3D.new()
	# Collide from BOTH sides. Unlike the visual mesh, the collision faces get
	# no winding correction, so their one-sided front can end up facing inward
	# (toward the planet centre) — leaving bodies to fall straight through the
	# surface from above. Double-sided collision makes the terrain solid
	# regardless of triangle winding.
	shape.backface_collision = true
	shape.set_faces(faces)
	return shape


## Generate a visual [ArrayMesh] for one HEALPix terrain chunk.
## Delegates to [method generate_mesh] with HEALPix mode enabled.
static func generate_mesh_healpix(
		data: PlanetData,
		nside: int,
		ipix: int,
		resolution: int,
		chunk_center: Vector3 = Vector3.ZERO) -> ArrayMesh:
	return generate_mesh(data, 0, 0.0, 0.0, 0.0, 0.0, resolution,
			chunk_center, nside, ipix)


## Generate a [ConcavePolygonShape3D] for one HEALPix terrain chunk.
## Delegates to [method generate_collision_shape] with HEALPix mode enabled.
static func generate_collision_shape_healpix(
		data: PlanetData,
		nside: int,
		ipix: int,
		resolution: int) -> ConcavePolygonShape3D:
	return generate_collision_shape(data, 0, 0.0, 0.0, 0.0, 0.0, resolution,
			nside, ipix)


# ------------------------------------------------------------------
# Internal
# ------------------------------------------------------------------

## Convert a world position to chunk-local space.
## Subtracts cc_f32 in float64 to preserve height precision, then snaps
## the small local offset to float32 for the GPU vertex buffer.
## At ±500 m local range the float32 ULP is ~60 µm — far below any
## visible seam threshold (skirt geometry covers the rest).
static func _world_to_local(world_pos: Vector3, cc_f32: Vector3,
		buf: PackedFloat32Array) -> Vector3:
	var local := world_pos - cc_f32
	buf[0] = local.x; buf[1] = local.y; buf[2] = local.z
	return Vector3(buf[0], buf[1], buf[2])


## Snap a Vector3 to float32 precision.
## Use this to ensure mi.position matches the cc_f32 used internally
## by generate_mesh, eliminating the float64↔float32 chunk-center
## mismatch that causes sub-metre vertex seams between adjacent chunks.
static func snap_to_f32(v: Vector3) -> Vector3:
	var buf := PackedFloat32Array([v.x, v.y, v.z])
	return Vector3(buf[0], buf[1], buf[2])


# ------------------------------------------------------------------
# Recipe-based biome helpers (replaces BiomeQuery for biome data)
# ------------------------------------------------------------------

## Resolve the export-level ipix for a given chunk nside/ipix.
## Returns -1 when the chunk is COARSER than the export level (a single
## chunk then spans many export tiles, so there is no canonical export
## ipix and callers should fall back to per-vertex vec2pix_nest).
static func _resolve_export_ipix(hp_nside: int, hp_ipix: int,
		export_nside: int) -> int:
	if hp_nside < export_nside:
		return -1
	var cur_nside := hp_nside
	var ipix := hp_ipix
	while cur_nside > export_nside:
		ipix = HEALPix.parent_pixel(ipix)
		cur_nside /= 2
	return ipix


## Get recipe data for this chunk: [populate_zones, linear_features,
## radial_features, craters].  Falls back to empty arrays gracefully.
static func _get_recipe_biome_data(data: PlanetData,
		hp_nside: int, hp_ipix: int) -> Array:
	if hp_nside <= 0:
		return [[], [], [], []]
	var eip := _resolve_export_ipix(hp_nside, hp_ipix, data.export_nside)
	return [
		data.get_chunk_populate_zones(eip),
		data.get_chunk_linear_features(eip),
		data.get_chunk_radial_features(eip),
		data.get_chunk_craters(eip),
	]


## Ray-casting point-in-polygon test (lon/lat space).
## [param vertices] is an Array of 2-element arrays [[lon,lat], ...].
static func _point_in_polygon_lonlat(lon: float, lat: float,
		vertices: Array) -> bool:
	var n := vertices.size()
	if n < 3:
		return false
	var inside := false
	var j := n - 1
	for i in n:
		var vi = vertices[i]
		var vj = vertices[j]
		var viy: float = vi[1]
		var vjy: float = vj[1]
		if ((viy > lat) != (vjy > lat)) and \
				(lon < (float(vj[0]) - float(vi[0])) * (lat - viy) / (vjy - viy) + float(vi[0])):
			inside = not inside
		j = i
	return inside


## Check if a direction vector lies inside a populate zone.
## Returns true for "full" coverage, false for "point" coverage (no polygon),
## runs point-in-polygon for "partial" coverage.
static func _dir_in_populate_zone(dir: Vector3, zone: Dictionary) -> bool:
	var coverage: String = zone.get("coverage", "")
	if coverage == "full":
		return true
	if coverage == "point":
		return false
	var vertices: Array = zone.get("vertices", [])
	if vertices.size() < 3:
		return false
	var lonlat := BiomeQuery._dir_to_lonlat(dir)
	return _point_in_polygon_lonlat(lonlat.x, lonlat.y, vertices)


## Find all populate zones containing the given direction.
## Returns an array of zone Dictionaries (may be empty).
static func _query_zones_at_direction(dir: Vector3,
		populate_zones: Array) -> Array:
	var result: Array = []
	for z in populate_zones:
		if _dir_in_populate_zone(dir, z):
			result.append(z)
	return result


## Check if any populate zone has the given biome_type.
static func _zones_have_biome_type(zones: Array, btype: String) -> bool:
	for z in zones:
		if z.get("biome_type", "") == btype:
			return true
	return false


## Check if any populate zone has a biome matching the predicate (is_liquid, etc).
## Uses PlanetData.get_biome_by_type() for the lookup.
static func _zones_have_biome_property(data: PlanetData,
		zones: Array, prop: String) -> bool:
	for z in zones:
		var bd = data.get_biome_by_type(z.get("biome_type", ""))
		if bd and bd.get(prop):
			return true
	return false


## Check if any linear feature has the given biome type.
static func _linear_has_type(linear_features: Array, btype: String) -> bool:
	for lf in linear_features:
		if lf.get("type", "") == btype:
			return true
	return false


## Check if any radial feature has the given biome type.
static func _radial_has_type(radial_features: Array, btype: String) -> bool:
	for rf in radial_features:
		if rf.get("type", "") == btype:
			return true
	return false


## Compute per-vertex tangents from positions, normals, UVs and triangle indices.
## Returns a PackedFloat32Array suitable for Mesh.ARRAY_TANGENT
## (4 floats per vertex: tangent.xyz + bitangent sign).
## Uses the standard per-triangle accumulation method, then ortho-normalizes
## the tangent against the vertex normal (Gram-Schmidt) and computes the
## handedness sign so normal maps render correctly.
static func _compute_tangents(verts: PackedVector3Array,
		norms: PackedVector3Array,
		uv_arr: PackedVector2Array,
		idx: PackedInt32Array) -> PackedFloat32Array:
	var vcount := verts.size()
	var t_accum := PackedVector3Array()
	var b_accum := PackedVector3Array()
	t_accum.resize(vcount)
	b_accum.resize(vcount)
	var zero := Vector3.ZERO
	for vi in vcount:
		t_accum[vi] = zero
		b_accum[vi] = zero

	var tri_count := idx.size() / 3
	for ti in tri_count:
		var i0 := idx[ti * 3 + 0]
		var i1 := idx[ti * 3 + 1]
		var i2 := idx[ti * 3 + 2]
		var v0 := verts[i0]
		var v1 := verts[i1]
		var v2 := verts[i2]
		var w0 := uv_arr[i0]
		var w1 := uv_arr[i1]
		var w2 := uv_arr[i2]
		var e1 := v1 - v0
		var e2 := v2 - v0
		var x1 := w1.x - w0.x
		var y1 := w1.y - w0.y
		var x2 := w2.x - w0.x
		var y2 := w2.y - w0.y
		var det := x1 * y2 - x2 * y1
		if absf(det) < 1e-12:
			continue
		var r := 1.0 / det
		var t := (e1 * y2 - e2 * y1) * r
		var b := (e2 * x1 - e1 * x2) * r
		t_accum[i0] += t
		t_accum[i1] += t
		t_accum[i2] += t
		b_accum[i0] += b
		b_accum[i1] += b
		b_accum[i2] += b

	var out := PackedFloat32Array()
	out.resize(vcount * 4)
	for vi in vcount:
		var n := norms[vi]
		var t := t_accum[vi]
		# Gram-Schmidt ortho-normalize against the normal.
		t = t - n * n.dot(t)
		if t.length_squared() < 1e-12:
			# Degenerate (no UV variation hit this vertex). Pick an
			# arbitrary tangent perpendicular to the normal.
			var ax := Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.UP
			t = ax - n * n.dot(ax)
		t = t.normalized()
		var sign_w := 1.0
		if n.cross(t).dot(b_accum[vi]) < 0.0:
			sign_w = -1.0
		out[vi * 4 + 0] = t.x
		out[vi * 4 + 1] = t.y
		out[vi * 4 + 2] = t.z
		out[vi * 4 + 3] = sign_w
	return out

