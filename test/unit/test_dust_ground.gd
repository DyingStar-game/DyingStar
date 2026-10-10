extends GutTest
## DustGround: the height grid the dust layer lies on. Over a smooth planet it reads flat (curvature
## only); a hill shows at its place and height; the build is spread over frames by its budget and the
## grid in use stays until the next one is complete; the camera going REBUILD_M away starts a new one.

const R: float = 6356000.0
const ANCHOR := Vector3(0.0, R, 0.0)


func _smooth(_dir: Vector3) -> float:
	return R


## A 30 m hill, 120 m wide (several 16 m cells), 200 m east of the anchor.
func _hill(dir: Vector3) -> float:
	var f: Array = DustGround.tangent_frame(ANCHOR)
	var p: Vector3 = dir * R - ANCHOR
	var d: float = p.distance_to((f[0] as Vector3) * 200.0)
	return R + 30.0 * exp(-d * d / (120.0 * 120.0))


func _build(g: DustGround, at: Vector3, fn: Callable) -> void:
	var guard := 0
	while not g.update(at, fn, 1000.0) and guard < DustGround.SIZE + 2:
		guard += 1


func test_a_smooth_planet_reads_flat() -> void:
	var g := DustGround.new()
	_build(g, ANCHOR, _smooth)
	assert_true(g.ready)
	var h: float = DustGround.ground_at(g._heights, g.east, g.north, Vector3.ZERO)
	assert_almost_eq(h, 0.0, 0.01, "under the anchor: the tangent plane")
	var corner: float = DustGround.ground_at(g._heights, g.east, g.north, g.east * 200.0 + g.north * 200.0)
	assert_almost_eq(corner, -(400.0 * 400.0 * 0.5) / (2.0 * R), 0.01, "200 m out: the curvature, millimetres")
	assert_true(is_nan(DustGround.ground_at(g._heights, g.east, g.north, g.east * (DustGround.half_m() + 100.0))),
			"off the grid")


func test_a_hill_shows_at_its_place_and_height() -> void:
	var g := DustGround.new()
	_build(g, ANCHOR, _hill)
	var top: float = DustGround.ground_at(g._heights, g.east, g.north, g.east * 200.0)
	assert_almost_eq(top, 30.0, 1.0, "the hill's top, 200 m east")
	var away: float = DustGround.ground_at(g._heights, g.east, g.north, -g.east * 400.0)
	assert_almost_eq(away, 0.0, 0.5, "400 m the other way: flat")
	assert_almost_eq(g.top_m, 30.0, 1.0, "the grid's highest ground: the hill")


func test_the_build_is_spread_over_frames_and_swaps_whole() -> void:
	var g := DustGround.new()
	assert_false(g.update(ANCHOR, _smooth, 0.0), "no budget: one row this frame")
	assert_false(g.ready)
	_build(g, ANCHOR, _smooth)
	assert_true(g.ready)
	var first: Vector3 = g.anchor
	var moved: Vector3 = ANCHOR + g.east * (DustGround.REBUILD_M + 10.0)
	assert_false(g.update(moved, _hill, 0.0), "a new build starts, one row only")
	assert_eq(g.anchor, first, "the grid in use stays until the new one is complete")
	_build(g, moved, _hill)
	assert_eq(g.anchor, moved, "then both swap at once")


func test_the_grid_reaches_the_near_layer_range() -> void:
	assert_true(DustGround.half_m() >= WeatherSky.NEAR_LAYER_RANGE_M, "the layer never marches past its ground")


func test_a_small_move_keeps_the_grid() -> void:
	var g := DustGround.new()
	_build(g, ANCHOR, _smooth)
	var first: Vector3 = g.anchor
	assert_false(g.update(ANCHOR + g.east * (DustGround.REBUILD_M - 5.0), _smooth))
	assert_eq(g.anchor, first)
