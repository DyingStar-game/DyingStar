extends GutTest
## InputEventCodec: a remapped binding saved to user://inputs.map comes back exactly as it was,
## modifiers included — the controls page writes it, SettingsManager reads it at boot.


func _key(physical: Key, alt := false) -> InputEventKey:
	var k := InputEventKey.new()
	k.physical_keycode = physical
	k.alt_pressed = alt
	return k


func _mouse(index: MouseButton, alt := false) -> InputEventMouseButton:
	var m := InputEventMouseButton.new()
	m.button_index = index
	m.alt_pressed = alt
	return m


func test_a_key_round_trips() -> void:
	var back: InputEventKey = InputEventCodec.decode(InputEventCodec.encode(_key(KEY_T))) as InputEventKey
	assert_eq(back.physical_keycode, KEY_T, "same key")
	assert_false(back.alt_pressed, "no modifier invented")


func test_a_key_keeps_its_alt() -> void:
	var back: InputEventKey = InputEventCodec.decode(InputEventCodec.encode(_key(KEY_T, true))) as InputEventKey
	assert_eq(back.physical_keycode, KEY_T, "same key")
	assert_true(back.alt_pressed, "Alt survives")


func test_a_mouse_button_keeps_its_alt() -> void:
	var text: String = InputEventCodec.encode(_mouse(MOUSE_BUTTON_WHEEL_UP, true))
	assert_eq(text, "Alt+mouse_4", "the modifier is written")
	var back: InputEventMouseButton = InputEventCodec.decode(text) as InputEventMouseButton
	assert_eq(back.button_index, MOUSE_BUTTON_WHEEL_UP, "same button")
	assert_true(back.alt_pressed, "Alt survives — the bug this codec exists for")


func test_a_plain_mouse_button_round_trips() -> void:
	var back: InputEventMouseButton = InputEventCodec.decode(
		InputEventCodec.encode(_mouse(MOUSE_BUTTON_MIDDLE))) as InputEventMouseButton
	assert_eq(back.button_index, MOUSE_BUTTON_MIDDLE, "same button")
	assert_false(back.alt_pressed, "no modifier invented")


func test_files_written_before_the_prefix_still_read() -> void:
	var back: InputEventMouseButton = InputEventCodec.decode("mouse_5") as InputEventMouseButton
	assert_eq(back.button_index, MOUSE_BUTTON_WHEEL_DOWN, "old format")
	assert_false(back.alt_pressed, "no modifier")


func test_the_label_names_the_modifier_of_a_mouse_binding() -> void:
	assert_true(InputLabel.for_event(_mouse(MOUSE_BUTTON_WHEEL_UP, true)).begins_with("Alt + "),
		"Alt + wheel reads as such in the controls page and the prompts")
