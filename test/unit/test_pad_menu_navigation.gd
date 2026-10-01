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


## The bar's entries are added after its hints: the second hint stood before them, both on the left.
func test_the_hints_stay_either_side_as_entries_are_added() -> void:
	var strip := TabStrip.new()
	strip.pad_navigation(&"ui_page_previous", &"ui_page_next")
	strip.add_entry(&"x", "x")
	strip.add_entry(&"y", "y")
	add_child_autofree(strip)
	assert_true(strip.get_child(0) is PadHint, "one before")
	assert_true(strip.get_child(strip.get_child_count() - 1) is PadHint, "one after the last entry")


## A device resting with an axis off centre (a trigger at -1) read as a player on the pad for good.
func test_a_pad_is_in_hand_when_something_changes_not_when_something_is_held() -> void:
	var rest := PackedFloat32Array()
	rest.resize(JOY_BUTTON_SDL_MAX + JOY_AXIS_SDL_MAX)
	rest[JOY_BUTTON_SDL_MAX + JOY_AXIS_TRIGGER_LEFT] = -1.0
	assert_false(InputDevice.moved(rest, rest), "a trigger resting at -1 is no one")
	var pulled := rest.duplicate()
	pulled[JOY_BUTTON_SDL_MAX + JOY_AXIS_TRIGGER_LEFT] = 1.0
	assert_true(InputDevice.moved(rest, pulled), "pulled, it is")
	var pressed := rest.duplicate()
	pressed[JOY_BUTTON_A] = 1.0
	assert_true(InputDevice.moved(rest, pressed), "a button going down")
	assert_false(InputDevice.moved(pressed, pressed), "but not one held")


func test_the_focused_entry_shows_its_button_without_moving_the_others() -> void:
	var strip := _strip()
	strip.allow_focus()
	var hint := strip.get_child(strip.button(&"a").get_index() + 1) as PadHint
	assert_not_null(hint, "a hint beside each entry")
	assert_eq(hint.custom_minimum_size.x, TabStrip.ACCEPT_HINT_WIDTH, "its room kept, shown or not")
	InputDevice.last = InputDevice.Kind.GAMEPAD
	hint._refresh()
	assert_eq(hint.self_modulate.a, 0.0, "hidden while its entry has not the focus")
	strip.button(&"a").grab_focus()
	hint._refresh()
	assert_eq(hint.self_modulate.a, 1.0, "shown when it has")
	assert_eq(hint.text, "A")
	strip.button(&"a").release_focus()
