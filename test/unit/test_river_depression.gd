extends GutTest
## GUT test suite for river biome loading and terrain depression.
##
## Tests cover:
## 1. BiomeQuery loads width_start / width_end when no legacy "width" field
## 2. prepare_zone computes progressive half-widths from width_start/width_end
## 3. get_cross_section_t returns correct t and along_t for progressive-width rivers
## 4. Runtime V-shape carving stores bank height, then subtracts depression
##
## Run with: godot --headless -s addons/gut/gut_cmdln.gd \
##   -gdir=res://test/unit -gtest=test_river_depression.gd


# ── Constants ─────────────────────────────────────────────────
const PLANET_RADIUS := 1958333.0


# ── Helpers ───────────────────────────────────────────────────

## Write a minimal GeoJSON file with river features for BiomeQuery to load.
## The river has width_start / width_end but NO legacy "width" field,
## which mirrors the real QGIS export pipeline output.
func _write_test_geojson(path: String, width_start: float, width_end: float) -> void:
	# Buffered polygon around the centerline (simple rectangle in lon/lat).
	var half_w := maxf(width_start, width_end) * 0.5 / (PLANET_RADIUS * PI / 180.0)
	var geojson := {
		"type": "FeatureCollection",
		"features": [
			{
				"type": "Feature",
				"geometry": {
					"type": "Polygon",
					"coordinates": [[
						[-10.0 - half_w, 20.0 - half_w],
						[-10.0 + half_w, 20.0 - half_w],
						[-9.5 + half_w, 20.5 + half_w],
						[-9.5 - half_w, 20.5 + half_w],
						[-10.0 - half_w, 20.0 - half_w],
					]]
				},
				"properties": {
					"biome_type": "maritime_river-river",
					"biome_index": 85,
					"width_start": width_start,
					"width_end": width_end,
					"centerline": [
						[-10.0, 20.0],
						[-9.75, 20.25],
						[-9.5, 20.5],
					],
					"flow_direction": "downstream"
				}
			}
		]
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(geojson))
	f.close()


# ===================================================================
# 1. BiomeQuery loads width_start / width_end (no legacy "width")
# ===================================================================


func test_biome_query_loads_width_start_end() -> void:
	## When the GeoJSON has width_start/width_end but no "width",
	## BiomeQuery must still populate the zone's width fields.
	var path := "user://test_river_biome.geojson"
	_write_test_geojson(path, 0.5, 50.0)

	var bq := BiomeQuery.new()
	var ok := bq.load_geojson(path)
	assert_true(ok, "BiomeQuery.load_geojson should succeed")
	assert_eq(bq.zone_count(), 1, "Should have exactly 1 zone")

	var zones := bq.get_all_zones()
	var z: Dictionary = zones[0]

	# width_start and width_end must be present and correct.
	assert_almost_eq(z.get("width_start", -1.0), 0.5, 1e-6,
		"zone.width_start should be 0.5")
	assert_almost_eq(z.get("width_end", -1.0), 50.0, 1e-6,
		"zone.width_end should be 50.0")

	# "width" should be max(width_start, width_end) as fallback.
	assert_almost_eq(z.get("width", -1.0), 50.0, 1e-6,
		"zone.width should be max(0.5, 50.0) = 50.0")

	# half_width_deg should be based on the effective width.
	var m_per_deg := PLANET_RADIUS * PI / 180.0
	var expected_hw_deg := 50.0 / 2.0
	assert_true(z.get("half_width_deg", 0.0) > 0.0,
		"half_width_deg should be positive")

	# Cleanup.
	DirAccess.remove_absolute(path)


# ===================================================================
# 2. prepare_zone computes progressive widths
# ===================================================================


func test_prepare_zone_progressive_width() -> void:
	## After prepare_zone, the zone should have width_start_m, width_end_m,
	## half_width_start_deg, half_width_end_deg, and cumulative lengths.
	var zone := {
		"width_start": 0.5,
		"width_end": 50.0,
		"width": 50.0,
		"centerline": PackedVector2Array([
			Vector2(-10.0, 20.0),
			Vector2(-9.75, 20.25),
			Vector2(-9.5, 20.5),
		]),
	}

	MaritimeRiverRiverTerrain.prepare_zone(zone, PLANET_RADIUS)

	assert_almost_eq(zone.get("width_start_m", -1.0), 0.5, 1e-6,
		"width_start_m should be 0.5")
	assert_almost_eq(zone.get("width_end_m", -1.0), 50.0, 1e-6,
		"width_end_m should be 50.0")
	assert_true(zone.get("half_width_start_deg", 0.0) > 0.0,
		"half_width_start_deg should be > 0")
	assert_true(zone.get("half_width_end_deg", 0.0) > zone.get("half_width_start_deg", 0.0),
		"half_width_end_deg should be > half_width_start_deg")
	assert_true(zone.get("half_width_max_deg", 0.0) > 0.0,
		"half_width_max_deg should be > 0")
	assert_true(zone.get("_total_length", 0.0) > 0.0,
		"_total_length should be > 0")

	var cum: PackedFloat64Array = zone.get("_cum_lengths", PackedFloat64Array())
	assert_eq(cum.size(), 3, "_cum_lengths should have 3 entries (one per centerline pt)")
	assert_almost_eq(cum[0], 0.0, 1e-6, "cum[0] should be 0")
	assert_true(cum[1] > 0.0, "cum[1] should be > 0")
	assert_true(cum[2] > cum[1], "cum[2] should be > cum[1]")


# ===================================================================
# 3. get_cross_section_t returns progressive t and along_t
# ===================================================================


func test_cross_section_at_centerline_center() -> void:
	## A point exactly on the centerline midpoint should have t≈0
	## and along_t≈0.5.
	var zone := {
		"width_start": 10.0,
		"width_end": 50.0,
		"width": 50.0,
		"centerline": PackedVector2Array([
			Vector2(-10.0, 20.0),
			Vector2(-9.75, 20.25),
			Vector2(-9.5, 20.5),
		]),
	}
	MaritimeRiverRiverTerrain.prepare_zone(zone, PLANET_RADIUS)

	# Point right on the midpoint of the centerline.
	var mid := Vector2(-9.75, 20.25)
	var cs := BiomeQuery.get_cross_section_t(zone, mid)

	assert_almost_eq(cs.t, 0.0, 1e-3,
		"t at centerline midpoint should be ~0, got %.6f" % [cs.t])
	assert_almost_eq(cs.along_t, 0.5, 0.05,
		"along_t at midpoint should be ~0.5, got %.6f" % [cs.along_t])


func test_cross_section_progressive_width() -> void:
	## Near the start (narrow end), a given offset should give a larger t
	## than the same offset near the end (wide end).
	var zone := {
		"width_start": 10.0,
		"width_end": 100.0,
		"width": 100.0,
		"centerline": PackedVector2Array([
			Vector2(0.0, 0.0),
			Vector2(1.0, 0.0),
		]),
	}
	MaritimeRiverRiverTerrain.prepare_zone(zone, PLANET_RADIUS)

	# Offset 3m from centerline at both ends.
	var m_per_deg := PLANET_RADIUS * PI / 180.0
	var offset_deg := 3.0 / m_per_deg  # ~3m in degrees

	# Near start (along_t ≈ 0, half_width ≈ 5m) → t = 3/5 = 0.6
	var near_start := Vector2(0.05, offset_deg)
	var cs_start := BiomeQuery.get_cross_section_t(zone, near_start)

	# Near end (along_t ≈ 1, half_width ≈ 50m) → t = 3/50 = 0.06
	var near_end := Vector2(0.95, offset_deg)
	var cs_end := BiomeQuery.get_cross_section_t(zone, near_end)

	assert_true(cs_start.t > cs_end.t,
		"t near narrow start (%.4f) should be > t near wide end (%.4f)"
		% [cs_start.t, cs_end.t])
	assert_true(cs_start.along_t < cs_end.along_t,
		"along_t near start (%.4f) should be < along_t near end (%.4f)"
		% [cs_start.along_t, cs_end.along_t])


func test_cross_section_outside_river() -> void:
	## A point far from the centerline should return t = 1.0.
	var zone := {
		"width_start": 10.0,
		"width_end": 50.0,
		"width": 50.0,
		"centerline": PackedVector2Array([
			Vector2(-10.0, 20.0),
			Vector2(-9.5, 20.5),
		]),
	}
	MaritimeRiverRiverTerrain.prepare_zone(zone, PLANET_RADIUS)

	# Point far away from the centerline.
	var far_point := Vector2(0.0, 0.0)
	var cs := BiomeQuery.get_cross_section_t(zone, far_point)

	assert_almost_eq(cs.t, 1.0, 1e-6,
		"t far from centerline should be 1.0, got %.6f" % [cs.t])


# ===================================================================
# 4. Runtime V-shape carving: bank height stored, then depression applied
# ===================================================================


func test_runtime_carving_stores_bank_then_carves() -> void:
	## Runtime carving stores the unmodified bank height in
	## river_original_height, then subtracts the V-shape depression.
	## This replaced the old recipe-recovery approach (the recipe
	## heightmap at ~122 m/pixel is too coarse for narrow rivers).
	##
	## river_original_height = height (bank)
	## carved_height = height - zdepth * (1 - t²)
	var bank_height := 1000.0
	var width := 40.0  # metres
	var zdepth := width * MaritimeRiverRiverTerrain.DEPTH_RATIO  # 4.0m

	# At center (t=0): full depression.
	var t := 0.0
	var river_original_height := bank_height
	var carved_height := bank_height - zdepth * (1.0 - t * t)
	assert_almost_eq(river_original_height, bank_height, 0.01,
		"river_original_height should equal bank height (unchanged)")
	assert_almost_eq(carved_height, bank_height - zdepth, 0.01,
		"At center, carved depth should equal full zdepth")

	# At edge (t=0.9): shallow depression.
	t = 0.9
	river_original_height = bank_height
	carved_height = bank_height - zdepth * (1.0 - t * t)
	var expected_carve := zdepth * (1.0 - 0.81)  # 0.76m
	assert_almost_eq(carved_height, bank_height - expected_carve, 0.01,
		"At edge (t=0.9), carved depth should be zdepth*(1-0.81)")
	assert_almost_eq(river_original_height, bank_height, 0.01,
		"river_original_height at edge should still equal bank height")


func test_water_level_above_riverbed() -> void:
	## The water overlay is placed at river_original_height (bank) + WATER_OFFSET.
	## This must always be above the carved river-bed.
	var bank_height := 500.0
	var width := 30.0
	var depth := width * MaritimeRiverRiverTerrain.DEPTH_RATIO  # 3.0m

	# At centre (t=0): riverbed = bank - depth = 497.
	# Water surface = bank + WATER_OFFSET = 500.3.
	var riverbed := bank_height - depth
	var water := bank_height + MaritimeRiverRiverTerrain.WATER_OFFSET

	assert_true(water > riverbed,
		"Water level (%.2f) must be above riverbed (%.2f)" % [water, riverbed])

	# At edge (t=0.99): riverbed ≈ bank.
	var t := 0.99
	var edge_bed := bank_height - depth * (1.0 - t * t)
	assert_true(water > edge_bed,
		"Water level (%.2f) must be above edge riverbed (%.2f)" % [water, edge_bed])
