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


func test_every_modifier_survives_on_a_key() -> void:
	var key := _key(KEY_X)
	key.ctrl_pressed = true
	key.shift_pressed = true
	key.meta_pressed = true
	var text: String = InputEventCodec.encode(key)
	assert_eq(text, "Ctrl+Shift+Meta+X", "the same words on every system")
	var back: InputEventKey = InputEventCodec.decode(text) as InputEventKey
	assert_eq(back.physical_keycode, KEY_X, "same key")
	assert_true(back.ctrl_pressed and back.shift_pressed and back.meta_pressed, "all three survive")
	assert_false(back.alt_pressed, "and none is invented")


func test_a_bare_modifier_round_trips() -> void:
	for modifier: Key in BindingCapture.MODIFIERS:
		var back: InputEventKey = InputEventCodec.decode(InputEventCodec.encode(_key(modifier))) as InputEventKey
		assert_eq(back.physical_keycode, modifier, "sprint on Shift, the descent on Ctrl")
		assert_eq(back.get_modifiers_mask(), 0, "a key, not a key held with itself")


func test_a_mouse_button_keeps_ctrl_and_shift() -> void:
	var button := _mouse(MOUSE_BUTTON_MIDDLE)
	button.ctrl_pressed = true
	button.shift_pressed = true
	var back: InputEventMouseButton = InputEventCodec.decode(InputEventCodec.encode(button)) as InputEventMouseButton
	assert_eq(back.button_index, MOUSE_BUTTON_MIDDLE, "same button")
	assert_true(back.ctrl_pressed and back.shift_pressed, "both survive")


func test_the_label_names_the_modifier_of_a_mouse_binding() -> void:
	assert_true(InputLabel.for_event(_mouse(MOUSE_BUTTON_WHEEL_UP, true)).begins_with(
			InputLabel.alt_name(OS.get_name()) + " + "),
		"Alt + wheel reads as such in the controls page and the prompts")


func test_modifiers_are_named_as_the_keyboard_prints_them() -> void:
	assert_eq(InputLabel.alt_name("macOS"), "Option")
	assert_eq(InputLabel.alt_name("Windows"), "Alt")
	assert_eq(InputLabel.meta_name("macOS"), "Cmd")
	assert_eq(InputLabel.meta_name("Windows"), "Win")
	assert_eq(InputLabel.meta_name("Linux"), "Super")
