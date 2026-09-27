extends GutTest
## VehicleSteering: the keys turn the wheels progressively and the wheels stay where the pilot leaves
## them, apart from a caster drift back that only exists while rolling.

const DT := 1.0 / 60.0

var _s: VehicleSteering = null


func before_each() -> void:
	_s = VehicleSteering.new()
	_s.max_deg = 30.0
	_s.falloff_kmh = 80.0
	_s.min_ratio = 0.35
	_s.turn_speed = 0.8
	_s.return_speed = 1.0
	_s.self_center_speed = 0.3
	_s.self_center_ref_kmh = 50.0


func _run(angle: float, turn: float, kmh: float, seconds: float) -> float:
	var a: float = angle
	for i in int(round(seconds / DT)):
		a = _s.step(a, turn, kmh, DT)
	return a


func test_a_tap_turns_a_little_not_to_full_lock() -> void:
	var a: float = _run(0.0, 1.0, 0.0, 0.1)
	assert_almost_eq(a, 0.08, 0.002, "0.1 s at 0.8 rad/s")
	assert_lt(a, _s.lock_rad(0.0), "far from full lock")


func test_released_wheels_keep_their_angle_when_parked() -> void:
	var a: float = _run(0.0, 1.0, 0.0, 0.3)
	assert_eq(_run(a, 0.0, 0.0, 5.0), a, "no key, no speed: the angle is held")


func test_taps_add_up() -> void:
	var a: float = _run(0.0, 1.0, 0.0, 0.1)
	a = _run(a, 0.0, 0.0, 0.5)
	a = _run(a, 1.0, 0.0, 0.1)
	assert_almost_eq(a, 0.16, 0.004, "two taps, twice the angle")


func test_rolling_drifts_back_to_centre() -> void:
	var a: float = _run(0.0, 1.0, 0.0, 0.3)
	var after: float = _run(a, 0.0, 30.0, 0.5)
	assert_lt(after, a, "hands off while rolling: the wheel comes back")
	assert_gt(after, 0.0, "gently, not in one go")


func test_the_drift_grows_with_speed() -> void:
	var a: float = _run(0.0, 1.0, 0.0, 0.3)
	var slow: float = _run(a, 0.0, 10.0, 0.5)
	var fast: float = _run(a, 0.0, 50.0, 0.5)
	assert_lt(fast, slow, "faster = straighter")


func test_the_drift_never_crosses_centre() -> void:
	assert_eq(_run(0.05, 0.0, 80.0, 10.0), 0.0, "it stops at straight ahead")


func test_opposite_key_winds_back_faster() -> void:
	var a: float = 0.3
	var back: float = a - _run(a, -1.0, 0.0, 0.1)
	var out: float = _run(a, 1.0, 0.0, 0.1) - a
	assert_gt(back, out, "return_speed > turn_speed")


func test_held_key_stops_at_the_lock() -> void:
	assert_almost_eq(_run(0.0, 1.0, 0.0, 5.0), deg_to_rad(30.0), 1e-6, "full lock parked")
	assert_almost_eq(_run(0.0, -1.0, 0.0, 5.0), -deg_to_rad(30.0), 1e-6, "both sides")


func test_the_lock_shrinks_with_speed_and_pulls_a_held_angle_in() -> void:
	var parked: float = _run(0.0, 1.0, 0.0, 5.0)
	var lock_fast: float = _s.lock_rad(80.0)
	assert_almost_eq(lock_fast, deg_to_rad(30.0 * 0.35), 1e-6, "35 % of the lock at 80 km/h")
	assert_almost_eq(_s.step(parked, 0.0, 80.0, DT), lock_fast, 1e-6, "a parked full lock is clamped in")


func test_no_self_centre_means_no_drift() -> void:
	_s.self_center_speed = 0.0
	assert_eq(_run(0.2, 0.0, 60.0, 3.0), 0.2, "switched off: the wheels never move on their own")
