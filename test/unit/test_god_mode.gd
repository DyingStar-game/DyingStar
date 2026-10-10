extends GutTest
## God mode (the dev free-flight): the mouse wheel doubles or halves its speed, within bounds the server
## applies again, and the HUD shows it readably.

const GOD_MODE := preload("res://scenes/player/god_mode.gd")


func test_a_notch_doubles_or_halves_the_speed() -> void:
	assert_eq(GOD_MODE.next_speed(2000.0, 1), 4000.0)
	assert_eq(GOD_MODE.next_speed(2000.0, -1), 1000.0)


func test_the_speed_stays_within_bounds() -> void:
	assert_eq(GOD_MODE.next_speed(GOD_MODE.MAX_SPEED, 1), GOD_MODE.MAX_SPEED)
	assert_eq(GOD_MODE.next_speed(GOD_MODE.MIN_SPEED, -1), GOD_MODE.MIN_SPEED)
	assert_eq(GOD_MODE.clamp_speed(1.0e12), GOD_MODE.MAX_SPEED, "the server refuses a faster request")
	assert_eq(GOD_MODE.clamp_speed(-5.0), GOD_MODE.MIN_SPEED)


func test_the_hud_reads_metres_then_kilometres_per_second() -> void:
	assert_eq(GOD_MODE.speed_text(62.5), "63 m/s")
	assert_eq(GOD_MODE.speed_text(2000.0), "2 km/s")
	assert_eq(GOD_MODE.speed_text(1500.0), "1.5 km/s")
	assert_eq(GOD_MODE.speed_text(6.5536e7), "65536 km/s")


func test_its_actions_are_gated_dev_tools() -> void:
	for action: String in ["god_mode_speed", "god_mode_land"]:
		assert_eq(PlayerServer.DEV_TOOL_OF_ACTION.get(action), &"god_mode", "%s: off with the flight" % action)


func test_landing_has_its_own_key() -> void:
	assert_true(InputMap.has_action(&"god_mode_land"))
	assert_false(InputMap.action_get_events(&"god_mode_land").is_empty(), "the middle mouse button")


func test_no_landing_in_open_space() -> void:
	var drifter: Node3D = add_child_autofree(_Body.new())
	assert_null(GOD_MODE.landing_body(drifter), "no gravity, no planet above it: nowhere to land")


## A stand-in for a Player in open space: no gravity area, no Planet among its ancestors.
class _Body extends Node3D:
	var gravity_parents: Array = []
