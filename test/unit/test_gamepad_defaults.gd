extends GutTest
## Every action a player plays with has a gamepad button or stick out of the box; only the keyboard's
## own conveniences (chat, captures, the debug tools) are left to it.

## Bound on the keyboard only, on purpose: typing, filing captures, or tools for developers. The DataPad
## (toggle_services, F3) is there for now too: the pad has no button left to give it (Guide and Misc
## are the system's), and its way in on the pad is still to be chosen (a long press, a wheel entry).
const KEYBOARD_ONLY : Array[String] = [
	"toggle_services",
	"toggle_chat", "write_in_chat", "toggle_speaker", "toggle_microphone", "game_record", "screenshot",
	"screenshot_debug", "spawn_wheel", "toggle_eva", "zapette", "debug_time_forward", "debug_time_back",
	"debug_toggle_moon_lights", "debug_isolate_light", "toggle_debug", "walk_speed_up", "walk_speed_down",
	"vehicle_reset", "vehicle_horn_special", "vehicle_speed_limiter", "vehicle_limiter_up",
	"vehicle_limiter_down", "eva_stabilize",
]
## Mouse gestures, each with its pad twin: the same move made the pad's way (a drag is a stick, a wheel
## notch is a held trigger). The gesture has no pad binding; its twin must have one.
const MOUSE_GESTURES : Dictionary = {
	"star_map_orbit": "star_map_orbit_left",
	"star_map_zoom_step_in": "star_map_zoom_in",
	"star_map_zoom_step_out": "star_map_zoom_out",
}

## Reached on the pad through another action's button rather than a binding of its own: the controls
## help is a long press of the star map's button (the pad has no button left to give it).
const PAD_THROUGH : Dictionary = {
	"controls_help": "star_map",
}

func test_every_played_action_has_a_gamepad_default() -> void:
	InputMap.load_from_project_settings()
	var missing : Array[String] = []
	for action: StringName in InputMap.get_actions():
		var name : String = String(action)
		if name.begins_with("ui_") or KEYBOARD_ONLY.has(name) or MOUSE_GESTURES.has(name):
			continue
		if PAD_THROUGH.has(name):
			name = PAD_THROUGH[name]  # its way in on the pad is that action's button
			action = StringName(name)
		if InputDevice.bindings(action, InputDevice.Kind.GAMEPAD).is_empty():
			missing.append(name)
	assert_eq(missing, [] as Array[String], "actions with no gamepad binding")


func test_the_view_turns_with_the_right_stick() -> void:
	InputMap.load_from_project_settings()
	for action: StringName in [&"look_left", &"look_right", &"look_up", &"look_down"]:
		var pad : Array[InputEvent] = InputDevice.bindings(action, InputDevice.Kind.GAMEPAD)
		assert_eq(pad.size(), 1, "%s on a stick" % action)
		var motion := pad[0] as InputEventJoypadMotion
		assert_true(motion != null and (motion.axis == JOY_AXIS_RIGHT_X or motion.axis == JOY_AXIS_RIGHT_Y),
			"%s on the right stick" % action)
	assert_true(MenuConfig.labels_of(MenuConfig.ACTION_GROUPS["%%KM_GROUP_ON_FOOT"]).has("look_left"),
		"and listed in the controls page, to be changed")


func test_a_mouse_gesture_has_a_pad_twin() -> void:
	InputMap.load_from_project_settings()
	for gesture: String in MOUSE_GESTURES:
		var twin : StringName = StringName(MOUSE_GESTURES[gesture])
		assert_false(InputDevice.bindings(twin, InputDevice.Kind.GAMEPAD).is_empty(),
			"%s is made on the pad with %s" % [gesture, twin])


func test_the_star_map_turns_with_the_right_stick_and_its_own_actions() -> void:
	InputMap.load_from_project_settings()
	for action: StringName in [&"star_map_orbit_left", &"star_map_orbit_right", &"star_map_orbit_up",
			&"star_map_orbit_down"]:
		var motion := InputDevice.bindings(action, InputDevice.Kind.GAMEPAD)[0] as InputEventJoypadMotion
		assert_true(motion != null and (motion.axis == JOY_AXIS_RIGHT_X or motion.axis == JOY_AXIS_RIGHT_Y),
			"%s on the right stick" % action)
		assert_true(MenuConfig.labels_of(MenuConfig.ACTION_GROUPS["%%KM_GROUP_GENERAL"]).has(String(action)),
			"listed with the chart, apart from the walking look")


func test_moving_reads_the_left_stick_as_a_stick() -> void:
	InputMap.load_from_project_settings()
	var forward := InputDevice.bindings(&"move_forward", InputDevice.Kind.GAMEPAD)[0] as InputEventJoypadMotion
	assert_eq(forward.axis, JOY_AXIS_LEFT_Y)
	assert_eq(forward.axis_value, -1.0, "forward is the stick pushed up")
