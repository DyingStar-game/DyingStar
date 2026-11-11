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


func test_the_uv_torch_is_on_alt_u() -> void:
	var events := _defaults("toggle_torch_uv")
	assert_eq(events.size(), 1)
	var key := events[0] as InputEventKey
	assert_eq(key.physical_keycode, KEY_U)
	assert_true(key.alt_pressed, "Alt+U, so U alone stays the torch (InputCombo)")


func test_the_uv_beam_reaches_only_the_fluorescent_layer() -> void:
	var player: Node = load("res://scenes/player/player.tscn").instantiate()
	var beam := player.get_node("CameraPivot/Camera3D/Torch/UvBeam") as SpotLight3D
	assert_true(beam.light_negative, "a negative light: the crystal and rock shaders read it as UV")
	assert_eq(beam.light_cull_mask, Globals.RENDER_MASK_FLUORESCENT, "it darkens nothing else")
	assert_false(beam.shadow_enabled)
	player.free()


func test_the_uv_mode_is_a_whitelisted_player_property() -> void:
	for path: String in ["res://items_def/player_def.json", "res://addons/dyingstar/network_defs.json"]:
		var text: String = FileAccess.get_file_as_string(path)
		assert_true(text.contains("\"torch_uv\""), "%s lists torch_uv: Horizon drops what it does not know" % path)
