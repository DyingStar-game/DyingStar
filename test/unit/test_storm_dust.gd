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
	assert_eq(StormDust.saltation_rate(5.0, 6.0), 0.0, "under the threshold: nothing")
	assert_eq(StormDust.saltation_rate(6.0, 6.0), 0.0, "at it: nothing yet")
	assert_almost_eq(StormDust.saltation_rate(12.0, 6.0), 1.0, 1e-9, "twice the threshold: full")
	var some : float = StormDust.saltation_rate(8.0, 6.0)
	assert_between(some, 0.1, 0.6, "between: some (8 m/s on Tarsis III)")
	assert_lt(some, StormDust.saltation_rate(10.0, 6.0), "more wind, more sand")
	assert_eq(StormDust.saltation_rate(30.0, 6.0), 1.0, "capped")
	assert_eq(StormDust.saltation_rate(30.0, 0.0), 0.0, "no threshold known: nothing")


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
