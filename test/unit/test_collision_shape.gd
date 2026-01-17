extends GutTest
## GUT test suite for PlanetChunk.generate_collision_shape().
##
## Covers all code paths: HEALPix / cube-sphere modes, liquid / river /
## linear-feature / lava-river / point-biome / crater / cliff overlaps,
## heightmap sampling, export-ipix resolution walk, and edge cases.
##
## Run with: godot --headless -s addons/gut/gut_cmdln.gd \
##   -gdir=res://test/unit -gtest=test_collision_shape.gd


# ── Constants ─────────────────────────────────────────────────
const NSIDE := 4
const IPIX := 0
const RES := 8
const RADIUS := 1_000_000.0
const MAX_HEIGHT := 1000.0
const EXPECTED_FACE_COUNT := RES * RES * 6  # 384 floats → 64 triangles
const TOLERANCE := 5.0  # metres — large enough for float rounding on a 1e6 radius sphere


# ── Helpers ───────────────────────────────────────────────────

## Create a minimal PlanetData with cached chunk data for ipix.
func _make_planet_data(
		export_nside: int = NSIDE,
		radius: float = RADIUS,
		has_ocean: bool = false,
		biome_defs: Array = [],
		ipix: int = IPIX,
		populate_zones: Array = [],
		linear_features: Array = [],
		radial_features: Array = [],
		craters: Array = [],
		img: Image = null,
		p_max_height: float = MAX_HEIGHT) -> PlanetData:
	var data := PlanetData.new()
	data.export_nside = export_nside
	data.radius = radius
	data.has_ocean = has_ocean
	data.max_height = p_max_height
	data.height_offset = 0.0

	# Inject BiomeDefinitions.
	var defs: Array[BiomeDefinition] = []
	for entry in biome_defs:
		var bd := BiomeDefinition.new()
		bd.biome_type = entry.get("biome_type", "")
		bd.is_liquid = entry.get("is_liquid", false)
		bd.biome_index = entry.get("biome_index", -1)
		defs.append(bd)
	data.biome_definitions = defs

	# Store chunk image + recipe data in internal cache.
	var key := "hp_n%d_p%d" % [export_nside, ipix]
	var chunk_img := img
	if chunk_img == null:
		# 1×1 black image → sample_height returns 0.0 (flat terrain).
		chunk_img = Image.create(1, 1, false, Image.FORMAT_L8)
	data.store_chunk_image(key, chunk_img, craters,
			populate_zones, linear_features, radial_features)
	return data


## Return the pixel-center lon/lat of a HEALPix pixel as Vector2.
func _pixel_center_lonlat(nside: int, ipix: int) -> Vector2:
	var dir := HEALPix.pix2vec_nest(nside, ipix)
	return BiomeQuery._dir_to_lonlat(dir)


## Build a wide centerline that crosses the whole pixel, oriented
## roughly east-west at the pixel center.  Returns PackedVector2Array.
func _make_wide_centerline(nside: int, ipix: int,
		half_span_deg: float = 5.0) -> PackedVector2Array:
	var c := _pixel_center_lonlat(nside, ipix)
	return PackedVector2Array([
		Vector2(c.x - half_span_deg, c.y),
		Vector2(c.x + half_span_deg, c.y),
	])


## Build a polygon (square) that covers the whole pixel.
func _make_full_polygon(nside: int, ipix: int,
		half_deg: float = 20.0) -> Array:
	var c := _pixel_center_lonlat(nside, ipix)
	return [
		[c.x - half_deg, c.y - half_deg],
		[c.x + half_deg, c.y - half_deg],
		[c.x + half_deg, c.y + half_deg],
		[c.x - half_deg, c.y + half_deg],
	]


## Return the minimum and maximum vertex distance from origin.
func _vertex_range(shape: ConcavePolygonShape3D) -> Dictionary:
	var faces := shape.get_faces()
	var vmin := INF
	var vmax := -INF
	for v in faces:
		var d := v.length()
		if d < vmin:
			vmin = d
		if d > vmax:
			vmax = d
	return {"min": vmin, "max": vmax}


## Return true if at least one vertex is significantly depressed below
## the expected_radius (by more than threshold metres).
func _has_depressed_vertex(shape: ConcavePolygonShape3D,
		expected_radius: float, threshold: float = 1.0) -> bool:
	for v in shape.get_faces():
		if v.length() < expected_radius - threshold:
			return true
	return false


## Return the deepest depression (positive = below expected_radius).
func _max_depression(shape: ConcavePolygonShape3D,
		expected_radius: float) -> float:
	var worst := 0.0
	for v in shape.get_faces():
		var diff := expected_radius - v.length()
		if diff > worst:
			worst = diff
	return worst


# ===================================================================
# Phase 1: Structural / Basic Tests
# ===================================================================


func test_hp_mode_bare_terrain() -> void:
	var data := _make_planet_data()
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	assert_not_null(shape, "Shape should not be null")
	assert_eq(shape.get_faces().size(), EXPECTED_FACE_COUNT,
			"Face vertex count should be %d" % EXPECTED_FACE_COUNT)


func test_cube_sphere_bare_terrain() -> void:
	var data := _make_planet_data()
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, -1.0, 1.0, -1.0, 1.0, 4)
	assert_not_null(shape, "Shape should not be null")
	assert_eq(shape.get_faces().size(), 4 * 4 * 6,
			"Face vertex count should be 96 for res=4")


func test_resolution_variations() -> void:
	var data := _make_planet_data()
	for res in [4, 8, 16]:
		var shape := PlanetChunk.generate_collision_shape(
				data, 0, 0.0, 0.0, 0.0, 0.0, res, NSIDE, IPIX)
		assert_eq(shape.get_faces().size(), res * res * 6,
				"res=%d → face count should be %d" % [res, res * res * 6])


func test_vertices_on_sphere_surface() -> void:
	var data := _make_planet_data()
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	var vr := _vertex_range(shape)
	# With a 1×1 black heightmap (height=0), all vertices should be at radius.
	assert_almost_eq(vr.min, RADIUS, TOLERANCE,
			"Min vertex distance should be ~radius")
	assert_almost_eq(vr.max, RADIUS, TOLERANCE,
			"Max vertex distance should be ~radius")


func test_export_ipix_resolution() -> void:
	# nside=16 with export_nside=4 → the function walks _export_ipix >>= 2
	# twice (16→8→4).  ipix 0..15 at nside=16 all map to ipix 0 at nside=4.
	var data := _make_planet_data(NSIDE, RADIUS, false, [], IPIX)
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, 16, 0)
	assert_not_null(shape, "Shape should not be null for nside > export_nside")
	assert_eq(shape.get_faces().size(), EXPECTED_FACE_COUNT)


func test_heightmap_terrain() -> void:
	# Create a gradient heightmap: top row black (0.0), bottom row white (1.0).
	var img := Image.create(16, 16, false, Image.FORMAT_RF)
	for y in 16:
		var val := float(y) / 15.0
		for x in 16:
			img.set_pixel(x, y, Color(val, 0.0, 0.0))
	var data := _make_planet_data(NSIDE, RADIUS, false, [], IPIX,
			[], [], [], [], img, MAX_HEIGHT)
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	var vr := _vertex_range(shape)
	# Vertices should span from ~radius (black pixels) to ~radius+max_height (white pixels).
	assert_true(vr.max - vr.min > MAX_HEIGHT * 0.3,
			"Height range should span a significant fraction of max_height, got %.1f"
			% [vr.max - vr.min])
	assert_true(vr.min < RADIUS + MAX_HEIGHT * 0.5,
			"Min vertex should be below midpoint height")
	assert_true(vr.max > RADIUS + MAX_HEIGHT * 0.5,
			"Max vertex should be above midpoint height")


# ===================================================================
# Phase 2: Liquid / River Overlaps
# ===================================================================


func test_liquid_overlap_depression() -> void:
	var data := _make_planet_data(NSIDE, RADIUS, true,
			[{"biome_type": "maritime_river-ocean", "is_liquid": true}],
			IPIX,
			[{"biome_type": "maritime_river-ocean", "coverage": "full"}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	# All vertices should be depressed by 10m.
	var vr := _vertex_range(shape)
	assert_almost_eq(vr.min, RADIUS - 10.0, TOLERANCE,
			"Min vertex should be ~radius - 10")
	assert_almost_eq(vr.max, RADIUS - 10.0, TOLERANCE,
			"Max vertex should be ~radius - 10")


func test_liquid_no_ocean_flag() -> void:
	# is_liquid biome but has_ocean=false → no depression.
	var data := _make_planet_data(NSIDE, RADIUS, false,
			[{"biome_type": "maritime_river-ocean", "is_liquid": true}],
			IPIX,
			[{"biome_type": "maritime_river-ocean", "coverage": "full"}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	var vr := _vertex_range(shape)
	assert_almost_eq(vr.min, RADIUS, TOLERANCE,
			"No depression expected when has_ocean=false")


func test_river_overlap_depression() -> void:
	var cl := _make_wide_centerline(NSIDE, IPIX)
	var data := _make_planet_data(NSIDE, RADIUS, false, [], IPIX,
			[],  # no populate zones
			[{  # linear feature: river
				"type": "maritime_river-river",
				"centerline": cl,
				"width_start_m": 200.0,
				"width_end_m": 200.0,
			}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	# River carving: depth = width * DEPTH_RATIO * (1 - t²).
	# Grid vertices may not land exactly on the centerline, so t > 0.
	# Expect some depression > 0.5m (min zdepth clamp).
	assert_true(_has_depressed_vertex(shape, RADIUS, 0.4),
			"River should depress vertices near the centerline")
	var depression := _max_depression(shape, RADIUS)
	var max_possible := 200.0 * MaritimeRiverRiverTerrain.DEPTH_RATIO
	assert_true(depression > 0.4 and depression <= max_possible + 1.0,
			"Max depression should be in (0.4, %.1f], got %.1f" % [max_possible, depression])


func test_river_plus_liquid_combined() -> void:
	# River linear feature + ocean populate zone.
	# Vertices inside river → river carving; outside river in ocean → -10m.
	var cl := _make_wide_centerline(NSIDE, IPIX)
	var data := _make_planet_data(NSIDE, RADIUS, true,
			[{"biome_type": "maritime_river-ocean", "is_liquid": true}],
			IPIX,
			[{"biome_type": "maritime_river-ocean", "coverage": "full"}],
			[{
				"type": "maritime_river-river",
				"centerline": cl,
				"width_start_m": 200.0,
				"width_end_m": 200.0,
			}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	# Should have both river carving (>10m) and liquid depression (=10m).
	var depression := _max_depression(shape, RADIUS)
	assert_true(depression > 10.0,
			"Max depression should exceed liquid-only 10m, got %.1f" % depression)
	# Some vertices should be at exactly ~-10m (liquid fallback, not on river).
	var vr := _vertex_range(shape)
	assert_true(vr.max < RADIUS - 5.0,
			"Even the least-depressed vertex should be below radius (liquid fill)")


# ===================================================================
# Phase 3: Linear Feature Depressions
# ===================================================================


func _test_linear_feature(feature_type: String, expected_depth: float,
		msg: String) -> void:
	var cl := _make_wide_centerline(NSIDE, IPIX)
	var data := _make_planet_data(NSIDE, RADIUS, false, [], IPIX,
			[],
			[{
				"type": feature_type,
				"centerline": cl,
				"width_start_m": 500.0,
				"width_end_m": 500.0,
			}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	assert_true(_has_depressed_vertex(shape, RADIUS, 1.0),
			"%s should depress vertices" % msg)
	var depression := _max_depression(shape, RADIUS)
	# Allow a wide tolerance since vertex sampling depends on pixel geometry.
	assert_true(depression > expected_depth * 0.3,
			"%s: max depression %.1f should be > %.1f (30%% of default depth)"
			% [msg, depression, expected_depth * 0.3])
	assert_true(depression <= expected_depth + 5.0,
			"%s: max depression %.1f should be <= %.1f"
			% [msg, depression, expected_depth + 5.0])


func test_canyon_depression() -> void:
	_test_linear_feature("rocky_landform-canyon",
			RockyLandformCanyonTerrain.DEFAULT_DEPTH_M, "Canyon")


func test_crevasse_depression() -> void:
	_test_linear_feature("icy-ice_crevasse",
			IcyIceCrevasseTerrain.DEFAULT_DEPTH_M, "Crevasse")


func test_dry_river_bed_depression() -> void:
	_test_linear_feature("aride_desert-dry_river_bed",
			ArideDesertDryRiverBedTerrain.DEFAULT_DEPTH_M, "Dry river bed")


func test_pressure_canyon_depression() -> void:
	_test_linear_feature("rocky_landform-pressure_canyon",
			RockyLandformPressureCanyonTerrain.DEFAULT_DEPTH_M, "Pressure canyon")


func test_lava_river_depression() -> void:
	# Lava river uses a separate code path from the other linear features.
	var cl := _make_wide_centerline(NSIDE, IPIX)
	var data := _make_planet_data(NSIDE, RADIUS, false, [], IPIX,
			[],
			[{
				"type": "volcanic_geothermal-lava_river",
				"centerline": cl,
				"width_start_m": 500.0,
				"width_end_m": 500.0,
			}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	var expected := VolcanicGeothermalLavaRiverTerrain.DEFAULT_DEPTH_M
	assert_true(_has_depressed_vertex(shape, RADIUS, 1.0),
			"Lava river should depress vertices")
	var depression := _max_depression(shape, RADIUS)
	assert_true(depression > expected * 0.3,
			"Lava river depression %.1f should be > %.1f" % [depression, expected * 0.3])


func test_linear_depth_override() -> void:
	var cl := _make_wide_centerline(NSIDE, IPIX)
	var override_depth := 200.0
	var data := _make_planet_data(NSIDE, RADIUS, false, [], IPIX,
			[],
			[{
				"type": "rocky_landform-canyon",
				"centerline": cl,
				"width_start_m": 500.0,
				"width_end_m": 500.0,
				"depth_override": override_depth,
			}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	var depression := _max_depression(shape, RADIUS)
	# Should use depth_override (200) instead of DEFAULT_DEPTH_M (80).
	assert_true(depression > RockyLandformCanyonTerrain.DEFAULT_DEPTH_M + 10.0,
			"Depth override (%d) should produce deeper depression than default (%d), got %.1f"
			% [override_depth, RockyLandformCanyonTerrain.DEFAULT_DEPTH_M, depression])


# ===================================================================
# Phase 4: Point Biome Depressions
# ===================================================================


func _test_point_biome(biome_type: String, expected_radius_m: float,
		expected_depth_m: float, msg: String) -> void:
	# Use a very small planet so the pixel grid spacing is smaller than
	# the depression radius — guaranteeing vertices fall inside.
	# Note: _query_zones_at_direction skips "point" coverage, so we
	# use "full" coverage + lon/lat centroid (matching production data
	# where point biomes are exported as small polygons).
	var small_radius := 100.0
	var c := _pixel_center_lonlat(NSIDE, IPIX)
	var data := _make_planet_data(NSIDE, small_radius, false,
			[{"biome_type": biome_type}],
			IPIX,
			[{
				"biome_type": biome_type,
				"coverage": "full",
				"lon": c.x,
				"lat": c.y,
				"vertices": _make_full_polygon(NSIDE, IPIX, 20.0),
			}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, 16, NSIDE, IPIX)
	assert_true(_has_depressed_vertex(shape, small_radius, 0.5),
			"%s should depress vertices near centroid" % msg)
	var depression := _max_depression(shape, small_radius)
	# Depression should be at most the expected_depth_m (at centroid).
	assert_true(depression <= expected_depth_m + 1.0,
			"%s: depression %.1f should be <= %.1f"
			% [msg, depression, expected_depth_m + 1.0])


func test_cave_depression() -> void:
	_test_point_biome("rocky_landform-cave",
			CaveTerrain.ENTRANCE_RADIUS_M,
			CaveTerrain.ENTRANCE_DEPTH_M,
			"Cave")


func test_fumarole_depression() -> void:
	_test_point_biome("volcanic_geothermal-fumarole",
			VolcanicGeothermalFumaroleTerrain.DEPRESSION_RADIUS_M,
			VolcanicGeothermalFumaroleTerrain.DEPRESSION_DEPTH_M,
			"Fumarole")


func test_ice_geyser_depression() -> void:
	_test_point_biome("volcanic_geothermal-ice_geyser",
			VolcanicGeothermalIceGeyserTerrain.DEPRESSION_RADIUS_M,
			VolcanicGeothermalIceGeyserTerrain.DEPRESSION_DEPTH_M,
			"Ice geyser")


func test_mineral_thermal_source() -> void:
	_test_point_biome("volcanic_geothermal-mineral_thermal_source",
			VolcanicGeothermalMineralThermalSourceTerrain.DEPRESSION_RADIUS_M,
			VolcanicGeothermalMineralThermalSourceTerrain.DEPRESSION_DEPTH_M,
			"Mineral thermal source")


func test_hole_vertex_special() -> void:
	# Cave hole vertex: vertices within HOLE_RADIUS_M should be repositioned
	# to hole_dir * (radius + height - ENTRANCE_DEPTH_M), not just height-adjusted.
	# Use a small planet so grid vertices fall within HOLE_RADIUS_M (22m).
	# Use "full" coverage (same as production: _query_zones_at_direction
	# skips "point" coverage) + polygon with centroid at pixel center.
	var small_radius := 100.0
	var c := _pixel_center_lonlat(NSIDE, IPIX)
	var data := _make_planet_data(NSIDE, small_radius, false,
			[{"biome_type": "rocky_landform-cave"}],
			IPIX,
			[{
				"biome_type": "rocky_landform-cave",
				"coverage": "full",
				"lon": c.x,
				"lat": c.y,
				"vertices": _make_full_polygon(NSIDE, IPIX, 20.0),
			}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, 16, NSIDE, IPIX)
	# The deepest vertex (hole) should be at radius - ENTRANCE_DEPTH_M.
	var depression := _max_depression(shape, small_radius)
	assert_true(depression >= CaveTerrain.ENTRANCE_DEPTH_M - 5.0,
			"Hole vertex should be depressed by ~ENTRANCE_DEPTH_M (%.0f), got %.1f"
			% [CaveTerrain.ENTRANCE_DEPTH_M, depression])


# ===================================================================
# Phase 5: Crater & Cliff
# ===================================================================


func test_crater_displacement() -> void:
	var c := _pixel_center_lonlat(NSIDE, IPIX)
	var data := _make_planet_data(NSIDE, RADIUS, false, [], IPIX,
			[],  # no populate zones
			[],  # no linear features
			[],  # no radial features
			[{"lon": c.x, "lat": c.y, "radius_m": 5000.0, "depth_m": 200.0}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	# Crater creates a bowl depression and rim uplift.
	var vr := _vertex_range(shape)
	# Some vertices should be below radius (bowl).
	assert_true(vr.min < RADIUS - 10.0,
			"Crater bowl should depress vertices below radius, min=%.1f" % vr.min)


func test_cliff_displacement() -> void:
	# Cliff polygon covering the pixel center.
	var poly := _make_full_polygon(NSIDE, IPIX, 20.0)
	var data := _make_planet_data(NSIDE, RADIUS, false,
			[{"biome_type": "rocky_landform-cliff"}],
			IPIX,
			[{
				"biome_type": "rocky_landform-cliff",
				"coverage": "polygon",
				"vertices": poly,
			}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	# Interior vertices (far from edge) should be depressed by full DROP_M.
	# Edge vertices should have partial (quadratic ramp) displacement.
	assert_true(_has_depressed_vertex(shape, RADIUS, 5.0),
			"Cliff should depress interior vertices")
	var depression := _max_depression(shape, RADIUS)
	assert_true(depression > 0.0 and depression <= RockyLandformCliffTerrain.DROP_M + TOLERANCE,
			"Cliff depression should be <= DROP_M (%.0f), got %.1f"
			% [RockyLandformCliffTerrain.DROP_M, depression])


# ===================================================================
# Phase 6: Combined / Edge Cases
# ===================================================================


func test_multiple_overlaps() -> void:
	# Liquid + crater + cliff on the same chunk.
	var poly := _make_full_polygon(NSIDE, IPIX, 20.0)
	var c := _pixel_center_lonlat(NSIDE, IPIX)
	var data := _make_planet_data(NSIDE, RADIUS, true,
			[
				{"biome_type": "maritime_river-ocean", "is_liquid": true},
				{"biome_type": "rocky_landform-cliff"},
			],
			IPIX,
			[
				{"biome_type": "maritime_river-ocean", "coverage": "full"},
				{"biome_type": "rocky_landform-cliff", "coverage": "polygon",
					"vertices": poly},
			],
			[],  # no linear features
			[],  # no radial features
			[{"lon": c.x, "lat": c.y, "radius_m": 5000.0, "depth_m": 200.0}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	# All three displacements should apply cumulatively.
	var depression := _max_depression(shape, RADIUS)
	# Liquid (-10m) + cliff (up to -50m) + crater (up to -200m).
	assert_true(depression > 15.0,
			"Combined overlaps should produce > 15m total depression, got %.1f"
			% depression)


func test_empty_populate_zones() -> void:
	# HP mode with no recipe data loaded at all (no store_chunk_image call).
	var data := PlanetData.new()
	data.export_nside = NSIDE
	data.radius = RADIUS
	data.max_height = MAX_HEIGHT
	data.height_offset = 0.0
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	assert_not_null(shape, "Shape should not be null with no cached data")
	assert_eq(shape.get_faces().size(), EXPECTED_FACE_COUNT)


func test_centerline_too_short() -> void:
	# Linear feature with only 1 point in centerline → should be ignored.
	var data := _make_planet_data(NSIDE, RADIUS, false, [], IPIX,
			[],
			[{
				"type": "rocky_landform-canyon",
				"centerline": PackedVector2Array([Vector2(0.0, 0.0)]),
				"width_start_m": 500.0,
				"width_end_m": 500.0,
			}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	# Should not crash and should have no depression.
	var vr := _vertex_range(shape)
	assert_almost_eq(vr.min, RADIUS, TOLERANCE,
			"No depression expected with centerline too short")


func test_lava_river_depth_override() -> void:
	# Lava river with depth_override — separate code path from other linears.
	var cl := _make_wide_centerline(NSIDE, IPIX)
	var override_depth := 100.0
	var data := _make_planet_data(NSIDE, RADIUS, false, [], IPIX,
			[],
			[{
				"type": "volcanic_geothermal-lava_river",
				"centerline": cl,
				"width_start_m": 500.0,
				"width_end_m": 500.0,
				"depth_override": override_depth,
			}])
	var shape := PlanetChunk.generate_collision_shape(
			data, 0, 0.0, 0.0, 0.0, 0.0, RES, NSIDE, IPIX)
	var depression := _max_depression(shape, RADIUS)
	assert_true(depression > VolcanicGeothermalLavaRiverTerrain.DEFAULT_DEPTH_M + 5.0,
			"Lava river override (%d) should produce deeper depression than default (%d), got %.1f"
			% [override_depth, VolcanicGeothermalLavaRiverTerrain.DEFAULT_DEPTH_M, depression])
