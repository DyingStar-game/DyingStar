extends GutTest
## The menus driven without the mouse: the first press of the cross, the stick, an arrow or a button
## lands on the first item, then the focus moves item to item; up from the page reaches the bar above
## it and down from the bar the page again; B goes back.

const PAGE : PackedScene = preload("res://ui/settings_page/settings_page.tscn")


func after_each() -> void:
	InputDevice.last = InputDevice.Kind.KEYBOARD_MOUSE
	InputDevice.pointer = true
	var owner : Control = get_viewport().gui_get_focus_owner()
	if owner != null:
		owner.release_focus()


func _pad_button(index: JoyButton) -> InputEventJoypadButton:
	var b := InputEventJoypadButton.new()
	b.button_index = index
	b.pressed = true
	return b


func _action(action: StringName) -> InputEventAction:
	var a := InputEventAction.new()
	a.action = action
	a.pressed = true
	return a


func test_who_reaches_for_the_menu_without_the_mouse() -> void:
	assert_true(MenuFocus.wants_focus(_pad_button(JOY_BUTTON_A)), "a pad button")
	var stick := InputEventJoypadMotion.new()
	stick.axis = JOY_AXIS_LEFT_Y
	stick.axis_value = 0.9
	assert_true(MenuFocus.wants_focus(stick), "a stick pushed")
	stick.axis_value = 0.1
	assert_false(MenuFocus.wants_focus(stick), "not a stick at rest")
	var down := InputEventKey.new()
	down.keycode = KEY_DOWN
	down.physical_keycode = KEY_DOWN
	down.pressed = true
	assert_true(MenuFocus.wants_focus(down), "an arrow key")
	var click := InputEventMouseButton.new()
	click.pressed = true
	assert_false(MenuFocus.wants_focus(click), "not the mouse")


func test_the_first_press_lands_on_the_bars_first_entry() -> void:
	var bar := TopBar.new()
	bar.add_entry(&"one", "one")
	bar.add_entry(&"two", "two")
	add_child_autofree(bar)
	bar._input(_pad_button(JOY_BUTTON_A))
	assert_eq(get_viewport().gui_get_focus_owner(), bar.tabs.button(&"one"), "the first entry has the focus")


func test_down_from_the_bar_hands_over_to_the_page() -> void:
	var bar := TopBar.new()
	bar.add_entry(&"one", "one")
	add_child_autofree(bar)
	var page : SettingsPage = PAGE.instantiate()
	add_child_autofree(page)
	bar.attach_page(page)
	assert_false(bar.leads_focus, "the page leads now")
	bar.tabs.button(&"one").grab_focus()
	bar._input(_action(&"ui_down"))
	assert_null(get_viewport().gui_get_focus_owner(), "the bar lets go")
	assert_not_null(page.settings_container.gui_get_focus_owner(), "the page's first line has it")


func test_down_from_the_bar_with_no_page_keeps_the_focus() -> void:
	var bar := TopBar.new()
	bar.add_entry(&"one", "one")
	add_child_autofree(bar)
	bar.tabs.button(&"one").grab_focus()
	bar._input(_action(&"ui_down"))
	assert_eq(get_viewport().gui_get_focus_owner(), bar.tabs.button(&"one"), "nowhere to go: it stays")


func test_a_bar_under_an_open_page_does_not_take_the_first_press() -> void:
	var bar := TopBar.new()
	bar.add_entry(&"one", "one")
	bar.leads_focus = false
	add_child_autofree(bar)
	bar._input(_pad_button(JOY_BUTTON_A))
	assert_null(get_viewport().gui_get_focus_owner())


func test_up_from_the_pages_first_line_reaches_the_bar() -> void:
	var page : CanvasLayer = PAGE.instantiate()
	add_child_autofree(page)
	assert_true(page.focus_first(), "the page has a first line")
	watch_signals(page)
	page._input(_action(&"ui_up"))
	assert_signal_emitted(page, "left_top")


func test_ok_is_named_with_the_pads_own_button() -> void:
	assert_string_ends_with(PadPopup.ok_text(InputDevice.Family.XBOX), "(A)")
	assert_string_ends_with(PadPopup.ok_text(InputDevice.Family.NINTENDO), "(B)",
		"the bottom button of a Nintendo pad says B")


func test_the_window_holds_the_focus_while_it_is_up() -> void:
	var popup := PadPopup.new()
	add_child(popup)
	assert_true(MenuFocus.modal, "the menus leave it the focus")
	var bar := TopBar.new()
	bar.add_entry(&"one", "one")
	add_child_autofree(bar)
	bar._input(_pad_button(JOY_BUTTON_A))
	assert_ne(get_viewport().gui_get_focus_owner(), bar.tabs.button(&"one"), "the A for OK is not the bar's")
	popup.close()
	assert_false(MenuFocus.modal)


func test_a_pad_unknown_by_name_is_still_a_pad() -> void:
	assert_eq(InputDevice.family_of("XInput Gamepad (GLFW)", false), InputDevice.Family.XBOX,
		"its shoulders LB / RB, not Button 10 / 11")


func test_a_stick_steers_a_wheel_as_the_mouse_does() -> void:
	var part : Vector2 = RadialMenu.stick_pointer(Vector2(0.5, 0), 110.0, 305.0, 110.0)
	assert_between(part.length(), 110.0, 305.0, "part way: in the ring")
	assert_gt(RadialMenu.stick_pointer(Vector2(1, 0), 110.0, 305.0, 110.0).length(), 305.0,
		"all the way: out in a submenu")


## Godot's own menu actions carry no gamepad button for pressing or going back: A did nothing on a
## focused entry. They are written out in project.godot with the pad's buttons and the left stick.
func test_a_presses_b_goes_back_and_the_stick_moves() -> void:
	InputMap.load_from_project_settings()
	assert_true(_pad_button(JOY_BUTTON_A).is_action_pressed(&"ui_accept"), "A presses")
	assert_true(_pad_button(JOY_BUTTON_B).is_action_pressed(&"ui_cancel"), "B goes back")
	var stick := InputEventJoypadMotion.new()
	stick.axis = JOY_AXIS_LEFT_Y
	stick.axis_value = 0.9
	assert_true(stick.is_action_pressed(&"ui_down"), "the left stick moves down")
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	assert_true(enter.is_action_pressed(&"ui_accept"), "and Enter still presses")


func test_the_triggers_and_bumpers_step_rather_than_reach_for_the_page() -> void:
	var rt := InputEventJoypadMotion.new()
	rt.axis = JOY_AXIS_TRIGGER_RIGHT
	rt.axis_value = 1.0
	assert_false(MenuFocus.wants_focus(rt), "RT steps the bar")
	assert_false(MenuFocus.wants_focus(_pad_button(JOY_BUTTON_RIGHT_SHOULDER)), "RB steps the tabs")
	assert_true(MenuFocus.wants_focus(_pad_button(JOY_BUTTON_DPAD_DOWN)), "the cross reaches for the page")


func test_after_a_change_on_the_pad_save_takes_the_focus_and_names_its_button() -> void:
	var config : Control = (load("res://ui/menu_config/MenuConfig.tscn") as PackedScene).instantiate()
	add_child_autofree(config)
	InputDevice.pointer = false
	InputDevice.last = InputDevice.Kind.GAMEPAD
	config._offer_save()
	await wait_process_frames(1)
	assert_true(config.save_config.has_focus(), "A saves straight away")
	assert_string_ends_with(config.save_config.text, "(A)")
