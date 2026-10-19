extends GutTest
## The gait: one speed rule for the server and the owner's animation (Player.gait_speed), and the ramp
## the owner's animation follows from its keys (PlayerClient.intent_step), the one the server gives
## the body -- so pressing Shift shows the run at once, not after the round trip.

const DT: float = 1.0 / 60.0

var _player: Player = null


func before_each() -> void:
	_player = Player.new()  # no scene: the speeds are exports, the mining tool is absent (null)


func after_each() -> void:
	_player.free()


func test_sprint_or_the_wheel_walk_speed() -> void:
	assert_eq(_player.gait_speed(true, 1.5, 0, false), _player.sprint_speed)
	assert_eq(_player.gait_speed(false, 2.5, 0, false), 2.5)


func test_the_stance_caps_the_gait() -> void:
	assert_eq(_player.gait_speed(true, 1.5, 1, false), _player.crouch_speed, "no sprint crouched")
	assert_eq(_player.gait_speed(true, 1.5, 2, false), _player.prone_speed)


func test_carrying_slows_down() -> void:
	assert_almost_eq(_player.gait_speed(true, 1.5, 0, true), _player.sprint_speed * _player.carry_speed_factor, 1e-6)


func test_a_sprint_is_reached_in_a_fraction_of_a_second() -> void:
	var intent := Vector2.ZERO
	var t := 0.0
	while intent.length() < _player.sprint_speed - 1e-4 and t < 2.0:
		intent = PlayerClient.intent_step(intent, Vector2(0, -1), _player.sprint_speed, _player.acceleration, DT)
		t += DT
	assert_lt(t, 0.2, "the 10 m/s² body took 0.5 s and the round trip came on top")
	assert_almost_eq(intent, Vector2(0, _player.sprint_speed), Vector2(1e-4, 1e-4), "-y input = forward")


func test_releasing_the_keys_stops_on_the_same_ramp() -> void:
	var intent := Vector2(0, 5.0)
	intent = PlayerClient.intent_step(intent, Vector2.ZERO, 5.0, 30.0, 0.1)
	assert_almost_eq(intent.length(), 2.0, 1e-4)


func test_a_diagonal_is_no_faster_than_straight_ahead() -> void:
	var intent := PlayerClient.intent_step(Vector2.ZERO, Vector2(1, -1), 5.0, 1000.0, 1.0)
	assert_almost_eq(intent.length(), 5.0, 1e-4, "normalized like the server's move direction")
	assert_gt(intent.x, 0.0, "+x = right")
