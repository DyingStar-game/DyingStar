extends GutTest
## DustLift: how much of its ground a wind lifts. The sand streams over its threshold (Owen's flux,
## averaged over the gusts, so it thickens without a step), the settled film from the first breeze.


func test_the_plains_blow_sand_once_the_wind_lifts_the_ground() -> void:
	assert_eq(DustLift.saltation_rate(0.0, 6.0), 0.0, "calm: nothing")
	assert_lt(DustLift.saltation_rate(3.0, 6.0), 1e-4, "half the threshold: the gusts never reach it")
	var below: float = DustLift.saltation_rate(5.5, 6.0)
	assert_between(below, 0.005, 0.1, "just under the threshold: the gusts already stream a little sand")
	assert_gt(DustLift.saltation_rate(6.0, 6.0), below, "at it: more")
	assert_almost_eq(DustLift.saltation_rate(12.0, 6.0), 1.0, 1e-9, "twice the threshold: full")
	var some: float = DustLift.saltation_rate(8.0, 6.0)
	assert_between(some, 0.1, 0.6, "between: some (8 m/s on Tarsis III)")
	assert_lt(some, DustLift.saltation_rate(10.0, 6.0), "more wind, more sand")
	assert_eq(DustLift.saltation_rate(30.0, 6.0), 1.0, "capped")
	assert_eq(DustLift.saltation_rate(30.0, 0.0), 0.0, "no threshold known: nothing")


func test_the_settled_film_lifts_from_the_first_breeze() -> void:
	assert_eq(DustLift.ground_lift(0.0, 6.0), 0.0, "dead calm: nothing moves")
	assert_gt(DustLift.ground_lift(0.5, 6.0), 0.0, "the first breeze already lifts a little")
	assert_gt(DustLift.ground_lift(3.0, 6.0), 0.02, "half the threshold: some dust, not sand")
	assert_lt(DustLift.film_rate(100.0), DustLift.FILM_MAX + 1e-9, "the film never makes a storm")
	assert_gt(DustLift.ground_lift(5.5, 6.0), DustLift.saltation_rate(5.5, 6.0), "the film adds to the sand")
	assert_eq(DustLift.ground_lift(30.0, 6.0), 1.0, "capped")
	assert_eq(DustLift.ground_lift(-1.0, 6.0), 0.0)


func test_the_sand_thickens_without_a_step() -> void:
	var last: float = 0.0
	var biggest_jump: float = 0.0
	for i in 121:
		var lift: float = DustLift.saltation_rate(float(i) * 0.1, 6.0)
		assert_true(lift >= last - 1e-9, "never less sand with more wind (%.1f m/s)" % (float(i) * 0.1))
		biggest_jump = maxf(biggest_jump, lift - last)
		last = lift
	assert_lt(biggest_jump, 0.04, "0.1 m/s more wind never switches the sand on")
