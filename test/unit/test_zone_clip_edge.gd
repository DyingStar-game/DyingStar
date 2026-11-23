extends GutTest
## A populate zone is clipped to each export tile's lon/lat box (biomes.py), and
## the extreme corner of a HEALPix tile's diamond lies ON that box. The
## point-in-polygon test is half-open: the four tiles meeting at such a corner
## answered in, in, out, out for the same zone, so their chunks gave the shared
## vertex different biome reliefs (14 cm on tarsis_3, 39.551 W 24.789 N).
## PlanetChunk._on_clip_edge makes the box edges inclusive.

const PlanetChunkScript := preload("res://scenes/planet/planet_chunk.gd")

## The corner where the four tiles met, and the zone pieces of two of them.
const CORNER_LON := -39.55078125
const CORNER_LAT := 24.78856071


func _dir(lon: float, lat: float) -> Vector3:
	var lo := deg_to_rad(lon)
	var la := deg_to_rad(lat)
	return Vector3(cos(la) * cos(lo), sin(la), -cos(la) * sin(lo))


func _zone(vertices: Array) -> Dictionary:
	return {"biome_type": "outcrop-plateau", "coverage": "partial", "vertices": vertices}


## One pack coordinate quantum (dsmp.COORD_SCALE): the stored box edge may sit
## that far on the wrong side of the corner.
const Q := 1.0e-7


## West tile: the piece ends on the box's east edge, through the corner.
func _west_piece() -> Dictionary:
	var e := CORNER_LON - Q
	return _zone([[-39.570445, 24.776186], [e, 24.776186], [e, 24.825178], [-39.570445, 24.825178]])


## North tile: the piece starts on the box's south edge, through the corner.
func _north_piece() -> Dictionary:
	var s := CORNER_LAT + Q
	return _zone([[-39.566697, s], [-39.506836, s], [-39.506836, 24.870763], [-39.566697, 24.870763]])


func test_the_tile_corner_is_in_the_zone_from_every_side() -> void:
	var d := _dir(CORNER_LON, CORNER_LAT)
	assert_true(PlanetChunkScript._dir_in_populate_zone(d, _west_piece()), "west tile")
	assert_true(PlanetChunkScript._dir_in_populate_zone(d, _north_piece()), "north tile")


func test_a_point_a_metre_past_the_clip_edge_is_out() -> void:
	var metre_deg := 1.0 / 111000.0
	assert_false(PlanetChunkScript._dir_in_populate_zone(
			_dir(CORNER_LON + metre_deg, 24.8), _west_piece()), "east of the west piece")
	assert_false(PlanetChunkScript._dir_in_populate_zone(
			_dir(-39.53, CORNER_LAT - metre_deg), _north_piece()), "south of the north piece")


func test_a_slanted_edge_keeps_the_half_open_rule() -> void:
	# Only meridian / parallel edges (the tile box) are widened: a point on a
	# slanted zone edge is decided by point-in-polygon alone.
	var tri := _zone([[0.0, 0.0], [1.0, 1.0], [1.0, 0.0]])
	assert_false(PlanetChunkScript._on_clip_edge(0.5, 0.5, tri["vertices"]))
	assert_true(PlanetChunkScript._on_clip_edge(1.0, 0.5, tri["vertices"]))


func test_an_indexed_zone_answers_as_its_whole_outline() -> void:
	# A zone indexed where it is made (PlanetChunk.index_populate_zone: bands of latitude, clip edges apart)
	# answers _dir_in_populate_zone as its whole outline does, bit for bit: on winding outlines clipped by a
	# tile's box, on that box's edges (within the clip tolerance) and at the tile corner above.
	for piece: Dictionary in [_west_piece(), _north_piece()]:
		var indexed := piece.duplicate(true)
		PlanetChunkScript.index_populate_zone(indexed)
		assert_true(indexed.has(PlanetChunkScript.ZONE_INDEX_KEY))
		assert_true(PlanetChunkScript._dir_in_populate_zone(_dir(CORNER_LON, CORNER_LAT), indexed), "the corner, indexed")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var mismatches := 0
	var inside := 0
	for shape in 12:
		var outline := []
		var count := 8 + shape * 40
		for k in count:
			var a := TAU * k / count
			var r := 0.6 + 0.35 * sin(a * (3 + shape % 5)) + rng.randf_range(-0.05, 0.05)
			outline.append([clampf(cos(a) * r, -0.7, 0.7), clampf(sin(a) * r * 0.4, -0.25, 0.25)])
		var whole := _zone(outline)
		var indexed := _zone(outline.duplicate(true))
		PlanetChunkScript.index_populate_zone(indexed)
		for k in 3000:
			var lon := rng.randf_range(-0.8, 0.8)
			var lat := rng.randf_range(-0.3, 0.3)
			if k % 5 == 0:  # on a box edge, within the clip tolerance
				lon = [-0.7, 0.7][k % 2] + rng.randf_range(-Q, Q)
			var d := _dir(lon, lat)
			var expected := PlanetChunkScript._dir_in_populate_zone(d, whole)
			inside += int(expected)
			if PlanetChunkScript._dir_in_populate_zone(d, indexed) != expected:
				mismatches += 1
	assert_eq(mismatches, 0, "the indexed zone answers as the whole outline")
	assert_gt(inside, 3000, "and many places are inside")
