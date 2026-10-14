extends GutTest
## The torch on foot and a vehicle's head lights each have their own key and pad button out of the
## box: the torch U and D-pad up, the head lights L and D-pad down (prone's on foot, not read while
## seated). Sharing L and D-pad up, one press at the wheel lit the torch with the head lights. Read
## from the project's defaults, not the live InputMap, which carries this machine's own remapping.


func _defaults(action: String) -> Array:
	return (ProjectSettings.get_setting("input/" + action) as Dictionary)["events"]


func _default_keys(action: String) -> Array[Key]:
	var keys : Array[Key] = []
	for event: InputEvent in _defaults(action):
		if event is InputEventKey:
			keys.append((event as InputEventKey).physical_keycode)
	return keys


func _default_buttons(action: String) -> Array[JoyButton]:
	var buttons : Array[JoyButton] = []
	for event: InputEvent in _defaults(action):
		if event is InputEventJoypadButton:
			buttons.append((event as InputEventJoypadButton).button_index)
	return buttons


func test_the_torch_is_on_u() -> void:
	assert_eq(_default_keys("toggle_flashlight"), [KEY_U] as Array[Key])
	assert_eq(_default_buttons("toggle_flashlight"), [JOY_BUTTON_DPAD_UP] as Array[JoyButton])


func test_the_head_lights_are_on_l() -> void:
	assert_eq(_default_keys("vehicle_lights"), [KEY_L] as Array[Key])
	assert_eq(_default_buttons("vehicle_lights"), [JOY_BUTTON_DPAD_DOWN] as Array[JoyButton],
			"prone's button on foot, free at the wheel")
