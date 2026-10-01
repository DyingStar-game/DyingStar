extends GutTest
## In the menus the gamepad steps through the tabs (shoulder buttons for the settings' categories,
## triggers for the controls' families), and their buttons are named either side of the row only while
## the player is on the pad.


func after_each() -> void:
	InputDevice.last = InputDevice.Kind.KEYBOARD_MOUSE


func _strip() -> TabStrip:
	var strip := TabStrip.new()
	for key: StringName in [&"a", &"b", &"c"]:
		strip.add_entry(key, String(key))
	add_child_autofree(strip)
	strip.set_active(&"a")
	return strip


func test_stepping_goes_round_the_ends() -> void:
	var strip := _strip()
	var picked : Array[StringName] = []
	strip.selected.connect(func(key: StringName) -> void: picked.append(key))
	strip.step(1)
	strip.step(-1)
	assert_eq(picked, [&"b", &"c"] as Array[StringName], "next from the first, previous round the start")


func test_a_hidden_entry_is_stepped_over() -> void:
	var strip := _strip()
	strip.button(&"b").visible = false
	var picked : Array[StringName] = []
	strip.selected.connect(func(key: StringName) -> void: picked.append(key))
	strip.step(1)
	assert_eq(picked, [&"c"] as Array[StringName])


func test_the_buttons_are_named_either_side_and_only_on_the_pad() -> void:
	var strip := _strip()
	strip.pad_navigation(&"ui_page_previous", &"ui_page_next")
	var first := strip.get_child(0) as PadHint
	var last := strip.get_child(strip.get_child_count() - 1) as PadHint
	assert_not_null(first, "a hint before the tabs")
	assert_not_null(last, "and one after")
	first._refresh()
	assert_eq(first.text, "LB", "named after the button bound")
	assert_eq(first.self_modulate.a, 0.0, "hidden with the mouse in hand")
	InputDevice.last = InputDevice.Kind.GAMEPAD
	first._refresh()
	assert_eq(first.self_modulate.a, 1.0, "shown on the gamepad")


func test_the_settings_and_the_controls_step_with_the_pad() -> void:
	InputMap.load_from_project_settings()
	for action: StringName in [&"ui_page_previous", &"ui_page_next", &"ui_subpage_previous", &"ui_subpage_next"]:
		assert_false(InputDevice.bindings(action, InputDevice.Kind.GAMEPAD).is_empty(), "%s on the pad" % action)
