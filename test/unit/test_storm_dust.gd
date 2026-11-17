extends GutTest
## StormDust, the storm's grains past the camera: how many a second for how much dust (none in clear
## air, the full rate in a storm), and where they are born — upwind, spread sideways and up and down,
## or all around the camera when the air is calm and the dust hangs.


func test_the_rate_follows_the_dust() -> void:
	assert_eq(StormDust.rate_for(0.0), 0.0, "clear air")
	assert_eq(StormDust.rate_for(0.1), 0.0, "under the threshold: nothing flies")
	assert_almost_eq(StormDust.rate_for((StormDust.TAU_MIN + StormDust.TAU_FULL) * 0.5), StormDust.RATE_FULL * 0.5,
			1e-9, "halfway up: half the rate")
	assert_almost_eq(StormDust.rate_for(StormDust.TAU_FULL), StormDust.RATE_FULL, 1e-9, "a storm")
	assert_almost_eq(StormDust.rate_for(5.0), StormDust.RATE_FULL, 1e-9, "no more than full")


func test_grains_are_born_upwind_of_the_camera() -> void:
	var camera := Vector3(100.0, 50.0, -20.0)
	var wind := Vector3(10.0, 3.0, 0.0)  # an updraft in it, dropped: the ground is what the wind blows along
	var at : Vector3 = StormDust.birth_point(camera, wind, Vector3.UP, Vector3.ZERO)
	assert_eq(at, camera - Vector3(StormDust.UPWIND_M, 0.0, 0.0), "straight upwind, at eye height")
	var side : Vector3 = StormDust.birth_point(camera, wind, Vector3.UP, Vector3(1.0, 0.0, 0.0))
	assert_almost_eq(side.z, camera.z - StormDust.SPREAD_M, 1e-9, "sideways across the wind (up × east = -z)")
	assert_almost_eq(side.x, camera.x - StormDust.UPWIND_M, 1e-9)
	var high : Vector3 = StormDust.birth_point(camera, wind, Vector3.UP, Vector3(0.0, 1.0, 0.0))
	assert_almost_eq(high.y, camera.y + StormDust.HEIGHT_SPREAD_M, 1e-9, "up by the height spread")
	var along : Vector3 = StormDust.birth_point(camera, wind, Vector3.UP, Vector3(0.0, 0.0, -1.0))
	assert_almost_eq(along.x, camera.x - StormDust.UPWIND_M - StormDust.SPREAD_M * 0.5, 1e-9, "half the spread along")


func test_in_calm_air_the_dust_hangs_around_the_camera() -> void:
	var camera := Vector3(100.0, 50.0, -20.0)
	assert_eq(StormDust.birth_point(camera, Vector3(0.5, 0.0, 0.0), Vector3.UP, Vector3.ZERO), camera, "around you")
	var off : Vector3 = StormDust.birth_point(camera, Vector3.ZERO, Vector3.UP, Vector3(1.0, 1.0, 1.0))
	assert_almost_eq((off - camera).dot(Vector3.UP), StormDust.HEIGHT_SPREAD_M, 1e-9, "up by the height spread")
	var flat : Vector3 = off - camera - Vector3.UP * StormDust.HEIGHT_SPREAD_M
	assert_almost_eq(flat.length(), StormDust.SPREAD_M * sqrt(2.0), 1e-6, "a corner of the spread, flat")


func test_the_frame_follows_the_local_up() -> void:
	# On the far side of a planet "up" points down the world's Y: the grains are still born at eye level.
	var camera := Vector3.ZERO
	var up := Vector3.DOWN
	var wind := Vector3(0.0, 0.0, 8.0)
	var at : Vector3 = StormDust.birth_point(camera, wind, up, Vector3(0.0, 1.0, 0.0))
	assert_almost_eq(at.z, -StormDust.UPWIND_M, 1e-9, "upwind")
	assert_almost_eq(at.y, -StormDust.HEIGHT_SPREAD_M, 1e-9, "'up' is down there")


func test_the_plains_blow_sand_once_the_wind_lifts_the_ground() -> void:
	assert_eq(StormDust.saltation_rate(0.0, 6.0), 0.0, "calm: nothing")
	assert_lt(StormDust.saltation_rate(3.0, 6.0), 1e-4, "half the threshold: the gusts never reach it")
	var below: float = StormDust.saltation_rate(5.5, 6.0)
	assert_between(below, 0.005, 0.1, "just under the threshold: the gusts already stream a little sand")
	assert_gt(StormDust.saltation_rate(6.0, 6.0), below, "at it: more")
	assert_almost_eq(StormDust.saltation_rate(12.0, 6.0), 1.0, 1e-9, "twice the threshold: full")
	var some : float = StormDust.saltation_rate(8.0, 6.0)
	assert_between(some, 0.1, 0.6, "between: some (8 m/s on Tarsis III)")
	assert_lt(some, StormDust.saltation_rate(10.0, 6.0), "more wind, more sand")
	assert_eq(StormDust.saltation_rate(30.0, 6.0), 1.0, "capped")
	assert_eq(StormDust.saltation_rate(30.0, 0.0), 0.0, "no threshold known: nothing")


func test_the_settled_film_lifts_from_the_first_breeze() -> void:
	assert_eq(StormDust.ground_lift(0.0, 6.0), 0.0, "dead calm: nothing moves")
	assert_gt(StormDust.ground_lift(0.5, 6.0), 0.0, "the first breeze already lifts a little")
	assert_gt(StormDust.ground_lift(3.0, 6.0), 0.02, "half the threshold: some dust, not sand")
	assert_lt(StormDust.film_rate(100.0), StormDust.FILM_MAX + 1e-9, "the film never makes a storm")
	assert_gt(StormDust.ground_lift(5.5, 6.0), StormDust.saltation_rate(5.5, 6.0), "the film adds to the sand")
	assert_eq(StormDust.ground_lift(30.0, 6.0), 1.0, "capped")
	assert_eq(StormDust.ground_lift(-1.0, 6.0), 0.0)


func test_the_sand_thickens_without_a_step() -> void:
	var last: float = 0.0
	var biggest_jump: float = 0.0
	for i in 121:
		var lift: float = StormDust.saltation_rate(float(i) * 0.1, 6.0)
		assert_true(lift >= last - 1e-9, "never less sand with more wind (%.1f m/s)" % (float(i) * 0.1))
		biggest_jump = maxf(biggest_jump, lift - last)
		last = lift
	assert_lt(biggest_jump, 0.04, "0.1 m/s more wind never switches the sand on")


func test_a_low_population_is_born_at_its_own_distance_and_height() -> void:
	var camera := Vector3(100.0, 50.0, -20.0)
	var wind := Vector3(10.0, 0.0, 0.0)
	var at : Vector3 = StormDust.birth_point(camera, wind, Vector3.UP, Vector3.ZERO, 9.0, 7.0, 0.0)
	assert_eq(at, camera - Vector3(9.0, 0.0, 0.0))
	var side : Vector3 = StormDust.birth_point(camera, wind, Vector3.UP, Vector3(1.0, 1.0, 0.0), 9.0, 7.0, 0.0)
	assert_almost_eq(side.y, camera.y, 1e-9, "no height spread: at eye level, the ground is set after")
	assert_almost_eq(side.z, camera.z - 7.0, 1e-9)


func test_on_the_ground_without_a_planet_stands_over_the_point() -> void:
	assert_eq(StormDust.on_the_ground(null, Vector3(1.0, 2.0, 3.0), Vector3.UP, 0.5), Vector3(1.0, 2.5, 3.0))


func test_sheltered_births_are_pushed_past_the_walls() -> void:
	var eye := Vector3(0.0, 2.0, 0.0)
	assert_eq(StormDust.beyond(Vector3(3.0, 0.0, 4.0), eye, Vector3.UP, 0.0), Vector3(3.0, 0.0, 4.0), "open: untouched")
	var out : Vector3 = StormDust.beyond(Vector3(3.0, 0.0, 4.0), eye, Vector3.UP, 12.0)
	assert_almost_eq(Vector2(out.x, out.z).length(), 12.0, 1e-6, "pushed to the clear distance along the ground")
	assert_almost_eq(out.y, 0.0, 1e-9, "height kept")
	assert_almost_eq(Vector2(out.x, out.z).normalized().dot(Vector2(0.6, 0.8)), 1.0, 1e-6, "same direction")
	assert_eq(StormDust.beyond(Vector3(20.0, 0.0, 0.0), eye, Vector3.UP, 12.0), Vector3(20.0, 0.0, 0.0), "already outside")
