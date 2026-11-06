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
	assert_false(g.update(ANCHOR, _smooth, 0.0), "no budget: one cell this frame")
	assert_false(g.ready)
	_build(g, ANCHOR, _smooth)
	assert_true(g.ready)
	var first: Vector3 = g.anchor
	var moved: Vector3 = ANCHOR + g.east * (DustGround.REBUILD_M + 10.0)
	assert_false(g.update(moved, _hill, 0.0), "a new build starts, one cell only")
	assert_eq(g.anchor, first, "the grid in use stays until the new one is complete")
	_build(g, moved, _hill)
	assert_ne(g.anchor, first, "then both swap at once")
	assert_lt(g.anchor.distance_to(moved), DustGround.CELL_M * DustGround.COLOUR_STEP,
			"slid by whole colour cells: within one of the camera")


func test_moving_on_asks_only_the_new_strips() -> void:
	var g := DustGround.new()
	_build(g, ANCHOR, _hill)
	assert_eq(g.last_build_cells, DustGround.SIZE * DustGround.SIZE, "the first grid asks every cell")
	var hill_top: float = DustGround.ground_at(g._heights, g.east, g.north, g.east * 200.0)
	var moved: Vector3 = ANCHOR + g.east * 128.0
	_build(g, moved, _hill)
	var strip: int = int(128.0 / DustGround.CELL_M) * DustGround.SIZE
	assert_eq(g.last_build_cells, strip, "128 m on: only the 8 new columns are asked")
	assert_eq(g.east, DustGround.tangent_frame(ANCHOR)[0], "the same plane, slid")
	var again: float = DustGround.ground_at(g._heights, g.east, g.north, g.east * 200.0 - (g.anchor - ANCHOR))
	assert_almost_eq(again, hill_top, 0.01, "the hill kept where it was, from the copied cells")


var _asked: int = 0


func _counted_hill(dir: Vector3) -> float:
	_asked += 1
	return _hill(dir)


## What a real query costs (~200 us on tarsis_3): the budget has something to run out on.
func _slow_smooth(_dir: Vector3) -> float:
	_asked += 1
	OS.delay_usec(200)
	return R


func test_a_build_stopped_in_a_row_ends_on_the_same_grid() -> void:
	var whole := DustGround.new()
	_build(whole, ANCHOR, _hill)
	var stepped := DustGround.new()
	_build(stepped, ANCHOR, _hill)
	var moved: Vector3 = ANCHOR + whole.north * 128.0
	_build(whole, moved, _hill)
	var calls := 0
	_asked = 0
	var most := 0
	while true:
		var before := _asked
		var swapped := stepped.update(moved, _counted_hill, 0.0)
		most = maxi(most, _asked - before)
		calls += 1
		if swapped or calls > DustGround.SIZE * DustGround.SIZE:
			break
	assert_eq(most, 1, "one cell an update, even in the rows of new cells")
	assert_eq(_asked, whole.last_build_cells, "and every new cell once")
	assert_eq(stepped.anchor, whole.anchor)
	assert_eq(stepped._heights, whole._heights, "cell by cell, the same grid")


func test_the_budget_holds_inside_a_row_of_new_cells() -> void:
	var g := DustGround.new()
	_build(g, ANCHOR, _smooth)
	var moved: Vector3 = ANCHOR + g.north * 128.0
	_asked = 0
	g.update(moved, _slow_smooth, DustGround.BUDGET_MS)
	assert_lte(_asked, int(DustGround.BUDGET_MS * 1000.0 / 200.0) + 1, "1.5 ms of 200 us queries, not the row's 128")


func test_a_whole_grid_gets_more_than_the_usual_budget_but_stays_bounded() -> void:
	var g := DustGround.new()
	_asked = 0
	g.update(ANCHOR, _slow_smooth, DustGround.BUDGET_MS)
	assert_lte(_asked, int(DustGround.WHOLE_BUILD_BUDGET_MS * 1000.0 / 200.0) + 1, "within its own budget")
	assert_gt(DustGround.WHOLE_BUILD_BUDGET_MS, DustGround.BUDGET_MS, "nothing to copy: it would take a minute")


func test_the_grid_reaches_the_near_layer_range() -> void:
	assert_true(DustGround.half_m() >= WeatherSky.NEAR_LAYER_RANGE_M, "the layer never marches past its ground")


func test_a_small_move_keeps_the_grid() -> void:
	var g := DustGround.new()
	_build(g, ANCHOR, _smooth)
	var first: Vector3 = g.anchor
	assert_false(g.update(ANCHOR + g.east * (DustGround.REBUILD_M - 5.0), _smooth))
	assert_eq(g.anchor, first)
