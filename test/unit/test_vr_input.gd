extends GutTest
## The VR controllers are played as a gamepad (VrInput): what is printed on them does what the same
## button does on a pad, and the right stick turns the body in steps. Fed through trackers of our own in
## the XRServer, as a runtime would feed them.

var _left := XRControllerTracker.new()
var _right := XRControllerTracker.new()
var _input: VrInput = null
var _player: Node3D = null


func before_each() -> void:
	_left.name = &"test_vr_left"
	_left.hand = XRPositionalTracker.TRACKER_HAND_LEFT
	_right.name = &"test_vr_right"
	_right.hand = XRPositionalTracker.TRACKER_HAND_RIGHT
	XRServer.add_tracker(_left)
	XRServer.add_tracker(_right)
	var fake := GDScript.new()
	fake.source_code = "extends Node3D\nvar mouse_motion := Vector2.ZERO\nvar camera_sensitivity := 2.0\n"
	fake.reload()
	_player = Node3D.new()
	_player.set_script(fake)
	var hands: Array[XRController3D] = []
	for tracker: StringName in [_left.name, _right.name]:
		var hand := XRController3D.new()
		hand.tracker = tracker
		_player.add_child(hand)
		hands.append(hand)
	_input = VrInput.new()
	_input.menu_has_mouse = func() -> bool: return false
	_input.setup(_player, hands[0], hands[1])
	_player.add_child(_input)
	add_child_autofree(_player)


func after_each() -> void:
	_player.free()  # VrInput lets go of every pad button and axis as it leaves
	Input.flush_buffered_events()
	XRServer.remove_tracker(_left)
	XRServer.remove_tracker(_right)


func _press(tracker: XRControllerTracker, input: StringName, value: Variant) -> void:
	tracker.set_input(input, value)
	_input._process(0.016)
	Input.flush_buffered_events()


func test_a_on_the_right_jumps() -> void:
	_press(_right, &"ax_button", true)
	assert_true(Input.is_action_pressed("jump"))
	_press(_right, &"ax_button", false)
	assert_false(Input.is_action_pressed("jump"))


func test_x_on_the_left_is_the_action_key_that_gets_out_of_bed() -> void:
	_press(_left, &"ax_button", true)
	assert_true(Input.is_action_pressed("action"))


func test_the_steam_frames_right_x_is_the_action_key_too() -> void:
	_press(_right, &"x_button", true)
	assert_true(Input.is_action_pressed("action"))


func test_menu_pauses() -> void:
	_press(_right, &"menu_button", true)
	assert_true(Input.is_action_pressed("pause"))


func test_the_left_stick_walks() -> void:
	_press(_left, &"primary", Vector2(0.0, 1.0))
	assert_almost_eq(Input.get_action_strength("move_forward"), 1.0, 0.01, "stick up is forward")
	_press(_left, &"primary", Vector2.ZERO)
	assert_eq(Input.get_action_strength("move_forward"), 0.0, "let go, it stops")


func test_the_right_stick_turns_one_step_per_push() -> void:
	_press(_right, &"primary", Vector2(1.0, 0.0))
	var step: float = -deg_to_rad(VrInput.SNAP_TURN_DEG) / 2.0
	assert_almost_eq(float(_player.get("mouse_motion").x), step, 1e-6, "one step to the right")
	_press(_right, &"primary", Vector2(1.0, 0.0))
	assert_almost_eq(float(_player.get("mouse_motion").x), step, 1e-6, "held: no second step")
	_press(_right, &"primary", Vector2.ZERO)
	_press(_right, &"primary", Vector2(-1.0, 0.0))
	assert_almost_eq(float(_player.get("mouse_motion").x), 0.0, 1e-6, "back to the centre, then a step left")


func test_in_a_menu_only_pause_and_back_reach_the_game() -> void:
	_input.menu_has_mouse = func() -> bool: return true
	_press(_right, &"ax_button", true)
	assert_false(Input.is_action_pressed("jump"), "the laser's trigger and A are the menu's")
	_press(_right, &"menu_button", true)
	assert_true(Input.is_action_pressed("pause"))
