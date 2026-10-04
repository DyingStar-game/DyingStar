extends GutTest
## The motor's revs come from the wheels it drives, not from the body: a fall or a jump with nobody on
## the throttle no longer reads as revs.


func test_one_revolution_covers_the_wheel_s_circumference() -> void:
	# 0.55 m wheel at 100 rev/min: 2π·0.55 m per rev, 6000 rev per hour.
	var kmh : float = Vehicle.wheel_kmh_of(PackedFloat32Array([100.0]), PackedFloat32Array([0.55]))
	assert_almost_eq(kmh, TAU * 0.55 * 100.0 * 60.0 / 1000.0, 0.001)
	assert_almost_eq(kmh, 20.73, 0.01, "about 20.7 km/h")


func test_the_driven_wheels_are_averaged() -> void:
	var kmh : float = Vehicle.wheel_kmh_of(PackedFloat32Array([100.0, 300.0]), PackedFloat32Array([0.5, 0.5]))
	var one : float = Vehicle.wheel_kmh_of(PackedFloat32Array([200.0]), PackedFloat32Array([0.5]))
	assert_almost_eq(kmh, one, 0.001, "the mean of the two")


func test_still_wheels_are_no_revs_and_reverse_keeps_its_sign() -> void:
	assert_eq(Vehicle.wheel_kmh_of(PackedFloat32Array([0.0, 0.0]), PackedFloat32Array([0.5, 0.5])), 0.0,
			"wheels that do not turn: no speed, however the body moves")
	assert_true(Vehicle.wheel_kmh_of(PackedFloat32Array([-100.0]), PackedFloat32Array([0.5])) < 0.0)
	assert_eq(Vehicle.wheel_kmh_of(PackedFloat32Array(), PackedFloat32Array()), 0.0, "no driven wheel")


## In the air, nothing holds a driven wheel back: throttle down, it spins up fast; foot off, it slows.
func test_a_free_wheel_spins_up_with_the_throttle_and_down_without() -> void:
	assert_almost_eq(Vehicle.free_wheel_step(20.0, 45.0, 120.0, 30.0, 0.1), 32.0, 0.001, "up at 120 km/h/s")
	assert_almost_eq(Vehicle.free_wheel_step(40.0, 0.0, 120.0, 30.0, 0.1), 37.0, 0.001, "down at 30 km/h/s")
	assert_eq(Vehicle.free_wheel_step(44.0, 45.0, 120.0, 30.0, 1.0), 45.0, "never past full speed")
	assert_almost_eq(Vehicle.free_wheel_step(-10.0, -45.0, 120.0, 30.0, 0.1), -22.0, 0.001, "in reverse too")
