extends GutTest
## ScreenPoke: clicking a screen within reach, the right index goes to the point and comes back. The
## tap is an EVENT ("tap:<n>:x:y:z"), relayed by the server only within an arm's reach of the body and
## no faster than a finger.

const PUPPET := "res://scenes/_universe/characters/humanoids/human_puppet.tscn"


func test_the_finger_goes_out_rests_and_comes_back() -> void:
	assert_eq(ScreenPoke.envelope(0.0), 0.0, "nothing before the click")
	assert_almost_eq(ScreenPoke.envelope(ScreenPoke.REACH_S * 0.5), 0.5, 1e-6, "half-way out")
	assert_eq(ScreenPoke.envelope(ScreenPoke.REACH_S + ScreenPoke.HOLD_S * 0.5), 1.0, "on the screen")
	assert_almost_eq(ScreenPoke.envelope(ScreenPoke.REACH_S + ScreenPoke.HOLD_S + ScreenPoke.BACK_S * 0.5),
			0.5, 1e-6, "half-way back")
	assert_eq(ScreenPoke.envelope(INF), 0.0, "over")


func test_the_wrist_stops_a_finger_short_of_the_point() -> void:
	var wrist: Vector3 = ScreenPoke.wrist_for(Vector3.ZERO, Vector3(0.0, 0.0, -0.6), 0.15)
	assert_almost_eq(wrist, Vector3(0.0, 0.0, -0.45), Vector3.ONE * 1e-6)
	assert_eq(ScreenPoke.wrist_for(Vector3.ZERO, Vector3(0.0, 0.0, -0.1), 0.15), Vector3.ZERO,
			"closer than a finger: the wrist stays at the shoulder")


func test_the_event_carries_its_point() -> void:
	var action: String = ScreenPoke.tap_action(7, Vector3(0.25, 1.5, -0.4))
	assert_eq(action, "tap:7:0.250:1.500:-0.400")
	assert_almost_eq(ScreenPoke.parse_tap(action), Vector3(0.25, 1.5, -0.4), Vector3.ONE * 1e-6)
	assert_ne(ScreenPoke.tap_action(8, Vector3(0.25, 1.5, -0.4)), action, "every tap a new value")
	assert_null(ScreenPoke.parse_tap("emote:wave:3"), "not a tap")


func test_the_server_relays_only_a_reachable_tap_at_a_finger_s_pace() -> void:
	assert_true(PlayerServer.may_relay_tap(Vector3(0.2, 1.6, -0.5), 1000))
	assert_false(PlayerServer.may_relay_tap(Vector3(0.0, 1.6, -3.0), 1000), "a screen across the room")
	assert_false(PlayerServer.may_relay_tap(Vector3(0.2, 1.6, -0.5), PlayerServer.TAP_MIN_MS - 1), "too fast")


func test_it_hangs_on_the_right_arm_after_the_others() -> void:
	var puppet: Node = (load(PUPPET) as PackedScene).instantiate()
	add_child_autofree(puppet)
	var skeleton: Skeleton3D = puppet.find_children("*", "Skeleton3D", true, false)[0]
	var poke: ScreenPoke = ScreenPoke.attach(skeleton)
	assert_not_null(poke, "the rig has a right arm")
	assert_eq(poke.get_index(), skeleton.get_child_count() - 3, "the IK, then the hand, then its markers")
	assert_false(poke.active, "at rest, the clip alone")
	assert_gt(poke._finger_length, 0.0, "the index measured")
