extends GutTest
## StarMapHelp: the star map's help line names the keys the player actually has, for the device in
## their hands, and leaves out a gesture nothing is bound to. The InputMap is the project's again
## after each test.

const KEY_R : int = 82


func before_each() -> void:
	InputMap.load_from_project_settings()


func after_each() -> void:
	InputMap.load_from_project_settings()


func test_the_mouse_line_names_the_mouse_buttons() -> void:
	var line : String = StarMapHelp.text(InputDevice.Kind.KEYBOARD_MOUSE)
	assert_string_contains(line, InputLabel.for_event(_mouse(MOUSE_BUTTON_LEFT)), "select")
	assert_string_contains(line, InputLabel.for_event(_mouse(MOUSE_BUTTON_RIGHT)), "reset")
	assert_string_contains(line, InputLabel.for_event(_mouse(MOUSE_BUTTON_WHEEL_UP)), "zoom by the wheel")


func test_a_rebound_gesture_shows_its_new_key() -> void:
	var key := InputEventKey.new()
	key.physical_keycode = KEY_R as Key
	InputDevice.rebind(&"star_map_reset", key)
	var line : String = StarMapHelp.text(InputDevice.Kind.KEYBOARD_MOUSE)
	assert_string_contains(line, InputLabel.for_event(key), "the key it was moved to")
	assert_false(line.contains(InputLabel.for_event(_mouse(MOUSE_BUTTON_RIGHT))), "not the old button")


func test_a_gesture_bound_to_nothing_is_left_out() -> void:
	InputMap.action_erase_events(&"star_map_reset")
	var line : String = StarMapHelp.text(InputDevice.Kind.KEYBOARD_MOUSE)
	assert_false(line.contains(TranslationServer.translate("%%HUD_MAP_HELP_RESET")), "nothing to press, no mention")


func test_the_pad_line_names_the_whole_stick_and_the_triggers() -> void:
	var line : String = StarMapHelp.text(InputDevice.Kind.GAMEPAD)
	var family : InputDevice.Family = InputDevice.likely_family()
	assert_string_contains(line, InputLabel.pad_stick_name(JOY_AXIS_RIGHT_X, family), "the stick turns the view")
	assert_false(line.contains(InputLabel.pad_axis_name(JOY_AXIS_RIGHT_X, -1.0, family)),
		"as a whole, not one of its directions")
	assert_string_contains(line, InputLabel.pad_axis_name(JOY_AXIS_TRIGGER_RIGHT, 1.0, family),
		"the triggers zoom, the wheel's notches having no pad binding")


func _mouse(index: MouseButton) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = index
	return event
