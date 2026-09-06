extends GutTest
## Suite for [method RoadTerrain.perp_deg] — the width the road ribbon is
## actually drawn at.
##
## The ribbon extrudes its centerline sideways in lon/lat DEGREES. Rotating a
## raw degree delta by 90° looks like a perpendicular and is not one: a degree
## of longitude is only cos(lat) as long as a degree of latitude, so the offset
## comes out short in longitude and skewed on a diagonal. The ribbon did exactly
## that, which made a north-south road ~9 % too narrow at 25° of latitude and
## 50 % too narrow at 60°, and left a diagonal road's edges not square to it.
##
## It matters beyond looks: a bridge deck is built to the road's TRUE metric
## width, so a ribbon narrowed by cos(lat) can never line up with the deck it
## runs onto.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_road_ribbon_width.gd

const RADIUS := 6356000.0

var _mpd: float


func before_each() -> void:
	_mpd = RADIUS * PI / 180.0


## Metric length of a lon/lat offset applied at [param lat].
func _metres(offset_deg: Vector2, lat: float) -> float:
	var ls := cos(deg_to_rad(lat))
	return Vector2(offset_deg.x * ls, offset_deg.y).length() * _mpd


## Half of a 6 m road, in degrees, the way the ribbon computes it.
func _half_width_deg() -> float:
	return 3.0 / _mpd


func _check_width(p0: Vector2, p1: Vector2) -> float:
	var perp := RoadTerrain.perp_deg(p0, p1)
	var lat := 0.5 * (p0.y + p1.y)
	return 2.0 * _metres(perp * _half_width_deg(), lat)


func test_an_east_west_road_is_its_stated_width() -> void:
	# The case the old code got right, kept so the fix cannot regress it.
	assert_almost_eq(_check_width(Vector2(-39.6, 24.8), Vector2(-39.5, 24.8)),
			6.0, 0.01)


func test_a_north_south_road_is_its_stated_width() -> void:
	# The case the old code got wrong by cos(lat): 5.44 m instead of 6.
	assert_almost_eq(_check_width(Vector2(-39.6, 24.8), Vector2(-39.6, 24.9)),
			6.0, 0.01)


func test_a_diagonal_road_is_its_stated_width() -> void:
	assert_almost_eq(_check_width(Vector2(-39.6, 24.8), Vector2(-39.5, 24.9)),
			6.0, 0.01)


func test_width_holds_at_a_high_latitude() -> void:
	# At 60° the old error was 50 %.
	assert_almost_eq(_check_width(Vector2(10.0, 60.0), Vector2(10.0, 60.1)),
			6.0, 0.02)
	assert_almost_eq(_check_width(Vector2(10.0, 60.0), Vector2(10.1, 60.05)),
			6.0, 0.02)


func test_the_offset_is_square_to_the_road() -> void:
	# A sheared ribbon is not merely narrow: its edges are not parallel to the
	# road, so the tarmac visibly leans away from the centerline.
	var p0 := Vector2(-39.6, 24.8)
	var p1 := Vector2(-39.5, 24.9)
	var lat := 0.5 * (p0.y + p1.y)
	var ls := cos(deg_to_rad(lat))
	var along := Vector2((p1.x - p0.x) * ls, p1.y - p0.y).normalized()
	var perp := RoadTerrain.perp_deg(p0, p1)
	var across := Vector2(perp.x * ls, perp.y).normalized()
	assert_almost_eq(along.dot(across), 0.0, 1e-9,
			"perpendicular in METRIC space, which is the space the player sees")


func test_a_degenerate_segment_is_reported_not_guessed() -> void:
	# Two identical points have no perpendicular; returning a plausible-looking
	# vector would put ribbon vertices in an arbitrary direction.
	assert_eq(RoadTerrain.perp_deg(Vector2(1.0, 2.0), Vector2(1.0, 2.0)),
			Vector2.ZERO)
