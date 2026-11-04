extends GutTest
## A prompt shows the mouse button to press as a picture of the mouse (InputLabel.rich_for_action),
## read at a glance and in any language, instead of "[Left click]"; a key keeps its name in brackets,
## the brackets escaped for the RichTextLabel that shows it.

const ACTION := &"test_input_icons_action"


func after_each() -> void:
	if InputMap.has_action(ACTION):
		InputMap.erase_action(ACTION)


func test_every_mouse_icon_exists() -> void:
	for index: int in InputLabel.MOUSE_ICONS:
		var path: String = InputLabel.MOUSE_ICONS[index]
		assert_true(ResourceLoader.exists(path), "%s for mouse button %d" % [path, index])
		assert_true(FileAccess.file_exists(path.get_basename() + ".txt"), "%s: its credit file" % path.get_file())


func test_a_bare_mouse_button_is_a_picture() -> void:
	_bind(_mouse(MOUSE_BUTTON_LEFT))
	var rich := InputLabel.rich_for_action(ACTION, 30)
	assert_string_starts_with(rich, "[img height=30]")
	assert_string_contains(rich, "mouse_left.png")
	assert_not_null(InputLabel.icon_for_event(_mouse(MOUSE_BUTTON_RIGHT)), "the right button too")


func test_a_mouse_button_with_a_modifier_keeps_its_words() -> void:
	var wheel := _mouse(MOUSE_BUTTON_WHEEL_UP)
	wheel.alt_pressed = true
	assert_null(InputLabel.icon_for_event(wheel), "Alt + wheel is read as words")
	_bind(wheel)
	assert_string_starts_with(InputLabel.rich_for_action(ACTION, 30), "[lb]Alt + ")


func test_a_key_keeps_its_name_in_escaped_brackets() -> void:
	var key := InputEventKey.new()
	key.physical_keycode = KEY_B
	_bind(key)
	var rich := InputLabel.rich_for_action(ACTION, 30)
	assert_eq(rich, "[lb]%s]" % InputLabel.for_action(ACTION), "[B] would be read as the bold tag")
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.text = rich + " " + InputLabel.escape("[x] Drop")
	add_child_autofree(label)
	assert_eq(label.get_parsed_text(), "[%s] [x] Drop" % InputLabel.for_action(ACTION), "shown as written")


func test_an_unbound_action_names_nothing() -> void:
	InputMap.add_action(ACTION)
	assert_eq(InputLabel.rich_for_action(ACTION, 30), "")
	assert_eq(InputLabel.rich_for_action(&"no_such_action_anywhere", 30), "")


func _bind(event: InputEvent) -> void:
	if not InputMap.has_action(ACTION):
		InputMap.add_action(ACTION)
	InputMap.action_add_event(ACTION, event)


func _mouse(index: MouseButton) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = index
	return e
