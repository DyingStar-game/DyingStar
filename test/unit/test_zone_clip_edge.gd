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
