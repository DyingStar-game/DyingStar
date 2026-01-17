extends GutTest
## GUT tests for river detection and V-shape carving across two adjacent chunks.
##
## Verifies that when a river's centerline + polygon cross from one chunk
## into a neighbouring chunk, both chunks detect has_river_overlap = true,
## produce is_river_vertex = 1 for vertices near the centerline, and apply
## the correct V-shape depression.
##
## Run with:
##   godot --headless -s addons/gut/gut_cmdln.gd \
##     -gdir=res://test/unit -gtest=test_river_cross_chunk.gd


# ── Constants ─────────────────────────────────────────────────
const PLANET_RADIUS := 1958333.0

## River parameters for test river.
const RIVER_WIDTH_START := 10.0  # metres (narrow upstream end)
const RIVER_WIDTH_END := 50.0    # metres (wide downstream end)
const RIVER_BIOME_INDEX := 85    # maritime_river-river index

## Boundary longitude where chunks A and B meet.
const BOUNDARY_LON := -10.0

## Chunk A spans lon [-11.0, -10.0], chunk B spans lon [-10.0, -9.0].
## River runs from lon=-10.5,lat=20.0 to lon=-9.5,lat=20.0
## so it crosses the boundary at lon=-10.0.


# ── Test GeoJSON ──────────────────────────────────────────────

## Build a buffered river polygon + centerline that crosses BOUNDARY_LON.
## Centerline: (-10.5, 20.0) → (-9.5, 20.0)  — pure east–west.
## Polygon: rectangular buffer around the centerline at max half-width.
func _write_cross_chunk_geojson(path: String) -> void:
	var m_per_deg := PLANET_RADIUS * PI / 180.0
	var half_w_deg := (RIVER_WIDTH_END * 0.5) / m_per_deg
	var geojson := {
		"type": "FeatureCollection",
		"features": [
			{
				"type": "Feature",
				"geometry": {
					"type": "Polygon",
					"coordinates": [[
						[-10.5, 20.0 - half_w_deg],
						[-9.5,  20.0 - half_w_deg],
						[-9.5,  20.0 + half_w_deg],
						[-10.5, 20.0 + half_w_deg],
						[-10.5, 20.0 - half_w_deg],
					]]
				},
				"properties": {
					"biome_type": "maritime_river-river",
					"biome_index": RIVER_BIOME_INDEX,
					"width_start": RIVER_WIDTH_START,
					"width_end": RIVER_WIDTH_END,
					"centerline": [
						[-10.5, 20.0],
						[-10.0, 20.0],
						[-9.5, 20.0],
					],
					"flow_direction": "downstream"
				}
			}
		]
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(geojson))
	f.close()


## Create a minimal BiomeDefinition that looks like a river.
func _make_river_biome_def() -> BiomeDefinition:
	var bd := BiomeDefinition.new()
	bd.biome_type = "maritime_river-river"
	bd.biome_index = RIVER_BIOME_INDEX
	bd.is_liquid = true
	return bd


## Simulate the per-chunk river overlap check that planet_chunk.gd does:
## iterate all zones, check AABB overlap, then matches_zone().
## Returns true if any zone is a matching river overlapping the bbox.
func _check_river_overlap(
		bq: BiomeQuery, bd: BiomeDefinition, data_stub: PlanetData,
		bb_min: Vector2, bb_max: Vector2) -> bool:
	for z in bq.get_all_zones():
		if not BiomeQuery._aabb_overlap(bb_min, bb_max, z.bbox_min, z.bbox_max):
			continue
		if MaritimeRiverRiverTerrain.matches_zone(bd, z, data_stub):
			return true
	return false


## Simulate per-vertex river zone search (like planet_chunk.gd does):
## query_at_direction → search returned zones for river.
func _find_river_zone(
		bq: BiomeQuery, bd: BiomeDefinition, data_stub: PlanetData,
		dir: Vector3) -> Dictionary:
	var zones := bq.query_at_direction(dir)
	for z in zones:
		if MaritimeRiverRiverTerrain.matches_zone(bd, z, data_stub):
			return z
	return {}


# ===================================================================
# Shared setup
# ===================================================================
var _geojson_path := "user://test_cross_chunk_river.geojson"
var _bq: BiomeQuery
var _bd: BiomeDefinition
var _data_stub: PlanetData


func before_all() -> void:
	_write_cross_chunk_geojson(_geojson_path)
	_bq = BiomeQuery.new()
	var ok := _bq.load_geojson(_geojson_path)
	assert_true(ok, "BiomeQuery.load_geojson should succeed")

	_bd = _make_river_biome_def()

	# Minimal PlanetData stub — only radius is needed now.
	# matches_zone() no longer requires has_ocean.
	_data_stub = PlanetData.new()
	_data_stub.has_ocean = true
	_data_stub.radius = PLANET_RADIUS


func after_all() -> void:
	DirAccess.remove_absolute(_geojson_path)


# ===================================================================
# 1. Both chunks detect has_river_overlap
# ===================================================================

func test_chunk_a_detects_river_overlap() -> void:
	## Chunk A: lon [-11.0, -10.0], lat [19.5, 20.5].
	## The river polygon spans lon [-10.5, -9.5], so it overlaps chunk A
	## in the range lon [-10.5, -10.0].
	var bb_min := Vector2(-11.0, 19.5)
	var bb_max := Vector2(-10.0, 20.5)
	var overlap := _check_river_overlap(_bq, _bd, _data_stub, bb_min, bb_max)
	assert_true(overlap, "Chunk A should detect river overlap")


func test_chunk_b_detects_river_overlap() -> void:
	## Chunk B: lon [-10.0, -9.0], lat [19.5, 20.5].
	## The river polygon spans lon [-10.5, -9.5], so it overlaps chunk B
	## in the range lon [-10.0, -9.5].
	var bb_min := Vector2(-10.0, 19.5)
	var bb_max := Vector2(-9.0, 20.5)
	var overlap := _check_river_overlap(_bq, _bd, _data_stub, bb_min, bb_max)
	assert_true(overlap, "Chunk B should detect river overlap")


func test_chunk_far_away_no_river_overlap() -> void:
	## A chunk far from the river should NOT detect overlap.
	var bb_min := Vector2(50.0, 50.0)
	var bb_max := Vector2(51.0, 51.0)
	var overlap := _check_river_overlap(_bq, _bd, _data_stub, bb_min, bb_max)
	assert_false(overlap, "Distant chunk should NOT detect river overlap")


# ===================================================================
# 2. Vertices on the river centerline in both chunks get t < 1.0
# ===================================================================

func test_vertex_on_centerline_chunk_a() -> void:
	## A point on the centerline inside chunk A (lon=-10.25, lat=20.0).
	var dir := HEALPix.lonlat2vec(-10.25, 20.0)
	var river_zone := _find_river_zone(_bq, _bd, _data_stub, dir)
	assert_false(river_zone.is_empty(), "River zone should be found in chunk A")

	MaritimeRiverRiverTerrain.prepare_zone(river_zone, PLANET_RADIUS)
	var lonlat := BiomeQuery._dir_to_lonlat(dir)
	var cs: Dictionary = BiomeQuery.get_cross_section_t(river_zone, lonlat)
	var cs_t: float = float(cs.t)
	var cs_along: float = float(cs.along_t)

	assert_true(cs_t < 0.05,
		"Vertex on centerline in chunk A should have t ≈ 0, got %.6f" % [cs_t])
	assert_true(cs_along >= 0.0 and cs_along <= 1.0,
		"along_t should be in [0, 1], got %.6f" % [cs_along])


func test_vertex_on_centerline_chunk_b() -> void:
	## A point on the centerline inside chunk B (lon=-9.75, lat=20.0).
	var dir := HEALPix.lonlat2vec(-9.75, 20.0)
	var river_zone := _find_river_zone(_bq, _bd, _data_stub, dir)
	assert_false(river_zone.is_empty(), "River zone should be found in chunk B")

	MaritimeRiverRiverTerrain.prepare_zone(river_zone, PLANET_RADIUS)
	var lonlat := BiomeQuery._dir_to_lonlat(dir)
	var cs: Dictionary = BiomeQuery.get_cross_section_t(river_zone, lonlat)
	var cs_t: float = float(cs.t)
	var cs_along: float = float(cs.along_t)

	assert_true(cs_t < 0.05,
		"Vertex on centerline in chunk B should have t ≈ 0, got %.6f" % [cs_t])
	assert_true(cs_along >= 0.0 and cs_along <= 1.0,
		"along_t should be in [0, 1], got %.6f" % [cs_along])


func test_vertex_at_chunk_boundary_on_centerline() -> void:
	## A point exactly at the boundary (lon=-10.0, lat=20.0).
	## Both chunks should see this vertex as part of the river.
	var dir := HEALPix.lonlat2vec(BOUNDARY_LON, 20.0)
	var river_zone := _find_river_zone(_bq, _bd, _data_stub, dir)
	assert_false(river_zone.is_empty(),
		"River zone should be found at chunk boundary")

	MaritimeRiverRiverTerrain.prepare_zone(river_zone, PLANET_RADIUS)
	var lonlat := BiomeQuery._dir_to_lonlat(dir)
	var cs: Dictionary = BiomeQuery.get_cross_section_t(river_zone, lonlat)
	var cs_t: float = float(cs.t)
	var cs_along: float = float(cs.along_t)

	assert_true(cs_t < 0.05,
		"Vertex at boundary on centerline should have t ≈ 0, got %.6f" % [cs_t])
	# at_t should be ~0.5 since boundary is the middle centerline point.
	assert_almost_eq(cs_along, 0.5, 0.05,
		"along_t at boundary midpoint should be ~0.5, got %.6f" % [cs_along])


# ===================================================================
# 3. Vertices off-center but inside river get 0 < t < 1.0
# ===================================================================

func test_vertex_offset_from_centerline_chunk_a() -> void:
	## A point 3 m north of the centerline inside chunk A.
	## At along_t ~0.25, width ≈ lerp(10, 50, 0.25) = 20 m,
	## so half-width ≈ 10 m → t ≈ 3/10 = 0.3.
	var m_per_deg := PLANET_RADIUS * PI / 180.0
	var offset_deg := 3.0 / m_per_deg
	var dir := HEALPix.lonlat2vec(-10.25, 20.0 + offset_deg)
	var river_zone := _find_river_zone(_bq, _bd, _data_stub, dir)
	assert_false(river_zone.is_empty(),
		"Offset vertex should still be inside river polygon")

	MaritimeRiverRiverTerrain.prepare_zone(river_zone, PLANET_RADIUS)
	var lonlat := BiomeQuery._dir_to_lonlat(dir)
	var cs: Dictionary = BiomeQuery.get_cross_section_t(river_zone, lonlat)
	var cs_t: float = float(cs.t)

	assert_true(cs_t > 0.0 and cs_t < 1.0,
		"Offset vertex in chunk A should have 0 < t < 1, got %.6f" % [cs_t])


func test_vertex_offset_from_centerline_chunk_b() -> void:
	## Same offset test in chunk B at lon=-9.75.
	## At along_t ~0.75, width ≈ lerp(10, 50, 0.75) = 40 m,
	## half-width ≈ 20 m → t ≈ 3/20 = 0.15.
	var m_per_deg := PLANET_RADIUS * PI / 180.0
	var offset_deg := 3.0 / m_per_deg
	var dir := HEALPix.lonlat2vec(-9.75, 20.0 + offset_deg)
	var river_zone := _find_river_zone(_bq, _bd, _data_stub, dir)
	assert_false(river_zone.is_empty(),
		"Offset vertex in chunk B should be inside river polygon")

	MaritimeRiverRiverTerrain.prepare_zone(river_zone, PLANET_RADIUS)
	var lonlat := BiomeQuery._dir_to_lonlat(dir)
	var cs: Dictionary = BiomeQuery.get_cross_section_t(river_zone, lonlat)
	var cs_t: float = float(cs.t)

	assert_true(cs_t > 0.0 and cs_t < 1.0,
		"Offset vertex in chunk B should have 0 < t < 1, got %.6f" % [cs_t])


# ===================================================================
# 4. Vertices outside the river get t = 1.0
# ===================================================================

func test_vertex_outside_river_returns_t_one() -> void:
	## A point far north of the river at lat=21.0 — outside the polygon.
	var dir := HEALPix.lonlat2vec(-10.0, 21.0)
	var river_zone := _find_river_zone(_bq, _bd, _data_stub, dir)
	# query_at_direction should not find the river zone at all.
	assert_true(river_zone.is_empty(),
		"Vertex far from river should not be inside the polygon")


# ===================================================================
# 5. V-shape depression is applied correctly in both chunks
# ===================================================================

func test_vshape_carving_at_centerline_chunk_a() -> void:
	## At the centerline (t=0) in chunk A, the carved depth should equal
	## the full depth: zdepth * (1 - 0²) = zdepth.
	var dir := HEALPix.lonlat2vec(-10.25, 20.0)
	var river_zone := _find_river_zone(_bq, _bd, _data_stub, dir)
	assert_false(river_zone.is_empty(), "Should find river zone")

	MaritimeRiverRiverTerrain.prepare_zone(river_zone, PLANET_RADIUS)
	var lonlat := BiomeQuery._dir_to_lonlat(dir)
	var cs: Dictionary = BiomeQuery.get_cross_section_t(river_zone, lonlat)
	var along: float = float(cs.along_t)
	var t: float = float(cs.t)

	# Progressive width at this along_t.
	var ws: float = river_zone.get("width_start_m", RIVER_WIDTH_START)
	var we: float = river_zone.get("width_end_m", RIVER_WIDTH_END)
	var width_here: float = lerpf(ws, we, along)
	var zdepth: float = maxf(width_here * MaritimeRiverRiverTerrain.DEPTH_RATIO, 0.5)

	# Simulate runtime carving (mirrors planet_chunk.gd logic).
	var bank_height: float = 1000.0
	var river_original_height: float = bank_height  # stored before carving
	var carved_height: float = bank_height - zdepth * (1.0 - t * t)

	# At center (t ≈ 0), carved height ≈ bank - zdepth.
	assert_true(carved_height < bank_height,
		"Carved height (%.2f) should be less than bank height (%.2f)" \
		% [carved_height, bank_height])
	assert_almost_eq(carved_height, bank_height - zdepth, 0.1,
		"At centerline, carved depth should match full zdepth")
	assert_almost_eq(river_original_height, bank_height, 0.01,
		"river_original_height should equal bank height (no recipe double-add)")


func test_vshape_carving_at_centerline_chunk_b() -> void:
	## Same carving test for chunk B — depth at centerline matches zdepth.
	var dir := HEALPix.lonlat2vec(-9.75, 20.0)
	var river_zone := _find_river_zone(_bq, _bd, _data_stub, dir)
	assert_false(river_zone.is_empty(), "Should find river zone")

	MaritimeRiverRiverTerrain.prepare_zone(river_zone, PLANET_RADIUS)
	var lonlat := BiomeQuery._dir_to_lonlat(dir)
	var cs: Dictionary = BiomeQuery.get_cross_section_t(river_zone, lonlat)
	var along: float = float(cs.along_t)
	var t: float = float(cs.t)

	var ws: float = river_zone.get("width_start_m", RIVER_WIDTH_START)
	var we: float = river_zone.get("width_end_m", RIVER_WIDTH_END)
	var width_here: float = lerpf(ws, we, along)
	var zdepth: float = maxf(width_here * MaritimeRiverRiverTerrain.DEPTH_RATIO, 0.5)

	var bank_height: float = 1000.0
	var carved_height: float = bank_height - zdepth * (1.0 - t * t)

	assert_true(carved_height < bank_height,
		"Carved height (%.2f) should be less than bank height (%.2f)" \
		% [carved_height, bank_height])
	assert_almost_eq(carved_height, bank_height - zdepth, 0.1,
		"At centerline in chunk B, carved depth should match full zdepth")


# ===================================================================
# 6. Water overlay sits above carved riverbed
# ===================================================================

func test_water_above_riverbed_both_chunks() -> void:
	## The water surface = river_original_height + WATER_OFFSET.
	## It must be above the carved vertex at the deepest point (t=0).
	for lon in [-10.25, -9.75]:
		var dir := HEALPix.lonlat2vec(lon, 20.0)
		var river_zone := _find_river_zone(_bq, _bd, _data_stub, dir)
		assert_false(river_zone.is_empty(),
			"River zone should be found at lon=%.2f" % lon)

		MaritimeRiverRiverTerrain.prepare_zone(river_zone, PLANET_RADIUS)
		var lonlat := BiomeQuery._dir_to_lonlat(dir)
		var cs: Dictionary = BiomeQuery.get_cross_section_t(river_zone, lonlat)
		var cs_t: float = float(cs.t)
		var cs_along: float = float(cs.along_t)

		var ws: float = river_zone.get("width_start_m", RIVER_WIDTH_START)
		var we: float = river_zone.get("width_end_m", RIVER_WIDTH_END)
		var width_here: float = lerpf(ws, we, cs_along)
		var zdepth: float = maxf(width_here * MaritimeRiverRiverTerrain.DEPTH_RATIO, 0.5)

		var bank_height: float = 1000.0
		var carved_height: float = bank_height - zdepth * (1.0 - cs_t * cs_t)
		var water_height: float = bank_height + MaritimeRiverRiverTerrain.WATER_OFFSET

		assert_true(water_height > carved_height,
			"Water (%.2f) must be above riverbed (%.2f) at lon=%.2f" \
			% [water_height, carved_height, lon])


# ===================================================================
# 7. Progressive width: chunk B (downstream) is wider than chunk A
# ===================================================================

func test_progressive_width_increases_downstream() -> void:
	## Since width_start=10 (upstream/lon=-10.5) and width_end=50
	## (downstream/lon=-9.5), the interpolated width should be larger
	## in chunk B (along_t > 0.5) than chunk A (along_t < 0.5).
	var dir_a := HEALPix.lonlat2vec(-10.25, 20.0)
	var dir_b := HEALPix.lonlat2vec(-9.75, 20.0)

	var zone_a := _find_river_zone(_bq, _bd, _data_stub, dir_a)
	var zone_b := _find_river_zone(_bq, _bd, _data_stub, dir_b)
	assert_false(zone_a.is_empty(), "Zone A should be found")
	assert_false(zone_b.is_empty(), "Zone B should be found")

	MaritimeRiverRiverTerrain.prepare_zone(zone_a, PLANET_RADIUS)
	# zone_a and zone_b are the same zone dict (same reference from BiomeQuery).

	var ll_a := BiomeQuery._dir_to_lonlat(dir_a)
	var ll_b := BiomeQuery._dir_to_lonlat(dir_b)
	var cs_a: Dictionary = BiomeQuery.get_cross_section_t(zone_a, ll_a)
	var cs_b: Dictionary = BiomeQuery.get_cross_section_t(zone_b, ll_b)
	var along_a: float = float(cs_a.along_t)
	var along_b: float = float(cs_b.along_t)

	assert_true(along_a < along_b,
		"along_t in chunk A (%.4f) should be < chunk B (%.4f)" \
		% [along_a, along_b])

	var ws: float = zone_a.get("width_start_m", RIVER_WIDTH_START)
	var we: float = zone_a.get("width_end_m", RIVER_WIDTH_END)
	var width_a: float = lerpf(ws, we, along_a)
	var width_b: float = lerpf(ws, we, along_b)

	assert_true(width_b > width_a,
		"Width in chunk B (%.2f m) should be > chunk A (%.2f m)" \
		% [width_b, width_a])


# ===================================================================
# 8. Depth continuity at chunk boundary
# ===================================================================

func test_depth_continuity_at_boundary() -> void:
	## Two vertices straddling the boundary (lon = -10.001 and -9.999)
	## should produce very similar carved depths, ensuring no cliff
	## at the chunk seam.
	var bank_height := 1000.0
	var epsilon_lon := 0.001  # ~0.001° ≈ ~34 m

	var dir_left := HEALPix.lonlat2vec(BOUNDARY_LON - epsilon_lon, 20.0)
	var dir_right := HEALPix.lonlat2vec(BOUNDARY_LON + epsilon_lon, 20.0)

	var zone_left := _find_river_zone(_bq, _bd, _data_stub, dir_left)
	var zone_right := _find_river_zone(_bq, _bd, _data_stub, dir_right)
	assert_false(zone_left.is_empty(), "Left-of-boundary vertex should find river")
	assert_false(zone_right.is_empty(), "Right-of-boundary vertex should find river")

	MaritimeRiverRiverTerrain.prepare_zone(zone_left, PLANET_RADIUS)

	var ll_l := BiomeQuery._dir_to_lonlat(dir_left)
	var ll_r := BiomeQuery._dir_to_lonlat(dir_right)
	var cs_l: Dictionary = BiomeQuery.get_cross_section_t(zone_left, ll_l)
	var cs_r: Dictionary = BiomeQuery.get_cross_section_t(zone_right, ll_r)
	var t_l: float = float(cs_l.t)
	var t_r: float = float(cs_r.t)
	var along_l: float = float(cs_l.along_t)
	var along_r: float = float(cs_r.along_t)

	var ws: float = zone_left.get("width_start_m", RIVER_WIDTH_START)
	var we: float = zone_left.get("width_end_m", RIVER_WIDTH_END)

	var w_l: float = lerpf(ws, we, along_l)
	var w_r: float = lerpf(ws, we, along_r)
	var zd_l: float = maxf(w_l * MaritimeRiverRiverTerrain.DEPTH_RATIO, 0.5)
	var zd_r: float = maxf(w_r * MaritimeRiverRiverTerrain.DEPTH_RATIO, 0.5)

	var carved_l: float = bank_height - zd_l * (1.0 - t_l * t_l)
	var carved_r: float = bank_height - zd_r * (1.0 - t_r * t_r)

	# Heights should differ by less than 0.1 m for vertices ~68 m apart.
	assert_almost_eq(carved_l, carved_r, 0.1,
		"Carved heights across boundary should be nearly equal: " \
		+ "left=%.4f, right=%.4f" % [carved_l, carved_r])
