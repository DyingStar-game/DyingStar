extends GutTest
## The drive axis pressed against the motion is the service brake: decelerate while rolling forward
## brakes, by how far it is pressed, and only drives backwards once the vehicle has (nearly) stopped.
## It used to reverse the engine at once, and the brake force played no part.

const VEHICLE := preload("res://scenes/_universe/vehicles/vehicle.gd")


func test_decelerating_while_rolling_forward_brakes() -> void:
	assert_eq(VEHICLE._service_brake(-1.0, 40.0), 1.0, "full press: full brake")
	assert_eq(VEHICLE._service_brake(-0.5, 40.0), 0.5, "half press: half brake")


func test_accelerating_while_rolling_back_brakes_too() -> void:
	assert_eq(VEHICLE._service_brake(1.0, -15.0), 1.0)


func test_with_the_motion_it_drives() -> void:
	assert_eq(VEHICLE._service_brake(1.0, 40.0), 0.0, "accelerating forward")
	assert_eq(VEHICLE._service_brake(-1.0, -10.0), 0.0, "reversing backwards")


func test_once_stopped_the_same_key_backs_up() -> void:
	assert_eq(VEHICLE._service_brake(-1.0, VEHICLE.REVERSE_ENGAGE_KMH * 0.5), 0.0)
	assert_eq(VEHICLE._service_brake(-1.0, 0.0), 0.0)



## The brakes are sized to the mass carried: the same deceleration empty or loaded. A fixed force braked
## a truck loaded with 3 t three times softer than an empty one.
func test_the_brakes_stop_a_loaded_truck_as_hard_as_an_empty_one() -> void:
	var dt := 1.0 / 60.0
	for mass_kg: float in [1425.0, 4425.0]:
		var per_wheel: float = VEHICLE.brake_impulse(7.0, mass_kg, dt, 4)
		var deceleration: float = per_wheel * 4.0 / dt / mass_kg
		assert_almost_eq(deceleration, 7.0, 1e-6, "%.0f kg" % mass_kg)
	assert_gt(VEHICLE.brake_impulse(7.0, 4425.0, dt, 4), VEHICLE.brake_impulse(7.0, 1425.0, dt, 4),
			"more impulse for more mass")


## Throttle released, the vehicle loses coast_drag of its speed each second on top of engine_brake: the
## force Godot's linear damping (mass x 0.1 x speed) used to apply, now only while coasting.
func test_coast_brake_matches_the_old_linear_damping() -> void:
	var dt: float = 1.0 / 60.0
	var mass_kg: float = 1600.0
	var speed_ms: float = 25.0
	var per_wheel: float = VEHICLE.coast_brake_impulse(0.0, 0.1, speed_ms, mass_kg, dt, 4)
	assert_almost_eq(per_wheel * 4.0 / dt, mass_kg * 0.1 * speed_ms, 1e-3, "m x 0.1 x v")


func test_coast_brake_adds_the_engine_brake_and_grows_with_speed() -> void:
	var dt: float = 1.0 / 60.0
	assert_almost_eq(VEHICLE.coast_brake_impulse(6.0, 0.1, 0.0, 1600.0, dt, 4), 6.0, 1e-6,
			"standing still: engine_brake alone")
	assert_eq(VEHICLE.coast_brake_impulse(6.0, 0.0, 25.0, 1600.0, dt, 4), 6.0, "no drag: engine_brake alone")
	assert_gt(VEHICLE.coast_brake_impulse(6.0, 0.1, 25.0, 1600.0, dt, 4),
			VEHICLE.coast_brake_impulse(6.0, 0.1, 10.0, 1600.0, dt, 4), "faster: harder")
	assert_eq(VEHICLE.coast_brake_impulse(6.0, 0.1, -10.0, 1600.0, dt, 4),
			VEHICLE.coast_brake_impulse(6.0, 0.1, 10.0, 1600.0, dt, 4), "rolling back brakes the same")
