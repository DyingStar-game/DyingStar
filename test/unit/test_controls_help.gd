extends GutTest
## The controls help (F1): its lines come from the InputMap at each opening — the player's own keys —
## numbered in order, each lighting the spots of the picture its keys sit on.


func test_lines_are_numbered_in_order_and_keep_their_sections() -> void:
	var rows : Array[Dictionary] = ControlsHelpRows.rows(InputDevice.Kind.KEYBOARD_MOUSE)
	assert_gt(rows.size(), 10, "the main actions")
	for i in rows.size():
		assert_eq(rows[i]["number"], i + 1)
	assert_eq(rows[0]["section"], "%%KM_GROUP_ON_FOOT")
	assert_eq(rows[0]["label"], "%%HELP_MOVE")
	assert_eq((rows[0]["names"] as PackedStringArray).size(), 4, "the four move keys on one line")


func test_looking_around_is_the_mouse_on_the_keyboard() -> void:
	var look : Dictionary = _row(ControlsHelpRows.rows(InputDevice.Kind.KEYBOARD_MOUSE), "%%HELP_LOOK")
	assert_true(ControlsHelpRows.MOUSE_MOTION_SPOT in look["spots"])


func test_a_rebound_key_shows_as_rebound() -> void:
	var events : Array[InputEvent] = InputMap.action_get_events(&"vehicle_horn").duplicate()
	var key := InputEventKey.new()
	key.physical_keycode = KEY_K
	InputMap.action_erase_events(&"vehicle_horn")
	InputMap.action_add_event(&"vehicle_horn", key)
	var horn : Dictionary = _row(ControlsHelpRows.rows(InputDevice.Kind.KEYBOARD_MOUSE), "%%ACT_VEHICLE_HORN")
	InputMap.action_erase_events(&"vehicle_horn")
	for event: InputEvent in events:
		InputMap.action_add_event(&"vehicle_horn", event)
	assert_eq(Array(horn["spots"]), ["key:%d" % KEY_K])


func test_spots_of_each_kind_of_binding() -> void:
	var button := InputEventJoypadButton.new()
	button.button_index = JOY_BUTTON_B
	assert_eq(ControlsHelpRows.spot_of(button), "b")
	var trigger := InputEventJoypadMotion.new()
	trigger.axis = JOY_AXIS_TRIGGER_RIGHT
	assert_eq(ControlsHelpRows.spot_of(trigger), "rt")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	assert_eq(ControlsHelpRows.spot_of(wheel), "wheel")


## A button that does two things carries both numbers (B: crouch on foot, brake at the wheel).
func test_one_spot_carries_every_line_it_serves() -> void:
	var rows : Array[Dictionary] = ControlsHelpRows.rows(InputDevice.Kind.GAMEPAD)
	var by_spot : Dictionary = ControlsHelpRows.numbers_by_spot(rows)
	var crouch : int = _row(rows, "%%ACT_CROUCH")["number"]
	var brake : int = _row(rows, "%%ACT_BRAKE")["number"]
	assert_eq(Array(by_spot["b"]), [crouch, brake])


func test_every_spot_used_by_default_is_on_its_picture() -> void:
	for spot: String in ControlsHelpRows.numbers_by_spot(ControlsHelpRows.rows(InputDevice.Kind.GAMEPAD)):
		assert_true(ControlsHelp.GAMEPAD_SPOTS.has(spot), "%s on the gamepad picture" % spot)
	for spot: String in ControlsHelpRows.numbers_by_spot(ControlsHelpRows.rows(InputDevice.Kind.KEYBOARD_MOUSE)):
		assert_true(spot.begins_with("key:") or ControlsHelp.MOUSE_SPOTS.has(spot), "%s drawn" % spot)


func test_the_help_opens_for_either_device_and_closes() -> void:
	var help := ControlsHelp.new()
	add_child_autofree(help)
	help.show_for(InputDevice.Kind.GAMEPAD)
	assert_true(help.visible)
	assert_eq(help.showing, InputDevice.Kind.GAMEPAD)
	help.hide_help()
	assert_false(help.visible)



## Resting on a key tells everything it does, family by family — beyond the legend's main actions.
func test_a_key_s_tooltip_tells_all_it_does_by_family() -> void:
	var pad_tips : Dictionary = ControlsHelpRows.tips_by_spot(InputDevice.Kind.GAMEPAD)
	var b : String = pad_tips["b"]
	assert_string_contains(b, tr("%%KM_GROUP_ON_FOOT").to_upper())
	assert_string_contains(b, tr("%%KM_GROUP_VEHICLE").to_upper())
	assert_string_contains(b, tr("%%ACT_CROUCH"))
	assert_string_contains(b, tr("%%ACT_BRAKE"))
	var keys : Dictionary = ControlsHelpRows.tips_by_spot(InputDevice.Kind.KEYBOARD_MOUSE)
	var h : String = keys["key:%d" % KEY_H]
	assert_string_contains(h, tr("%%ACT_VEHICLE_HORN"))
	assert_string_contains(h, tr("%%ACT_VEHICLE_HORN_SPECIAL"), "with its modifier, on the same key")
	assert_false(keys.has("key:%d" % KEY_2), "2 is only a developers' tool: no tooltip")


## It stays open like the star map: its own key, Escape, or on the pad View / B / Start closes it.
func test_it_closes_on_its_key_or_cancel() -> void:
	for action: StringName in [&"controls_help", &"pause", &"ui_cancel", &"star_map"]:
		var help := ControlsHelp.new()
		add_child_autofree(help)
		help.show_for(InputDevice.Kind.KEYBOARD_MOUSE)
		var press := InputEventAction.new()
		press.action = action
		press.pressed = true
		help._input(press)
		assert_false(help.visible, "%s closes it" % action)


## Open, it keeps the game's keys from the game (F2 would open the chart behind it), and its root stops
## every click; only the pointer moving goes through, to hover the keys.
func test_open_it_spends_every_key_and_click() -> void:
	var help := ControlsHelp.new()
	add_child_autofree(help)
	help.show_for(InputDevice.Kind.KEYBOARD_MOUSE)
	assert_eq((help.get_child(0) as Control).mouse_filter, Control.MOUSE_FILTER_STOP, "no click gets through")
	assert_true(ControlsHelp.blocks(InputEventKey.new()))
	assert_true(ControlsHelp.blocks(InputEventJoypadButton.new()))
	assert_false(ControlsHelp.blocks(InputEventMouseButton.new()), "clicks go to its tabs, its root stops them")
	assert_false(ControlsHelp.blocks(InputEventMouseMotion.new()))


func test_the_closing_hint_names_the_opening_key() -> void:
	assert_string_contains(ControlsHelp.closing_hint(InputDevice.Kind.KEYBOARD_MOUSE),
			ControlsHelp.open_key(InputDevice.Kind.KEYBOARD_MOUSE))

func _row(rows: Array[Dictionary], label: String) -> Dictionary:
	for row: Dictionary in rows:
		if row["label"] == label:
			return row
	return {}


## Two tabs switch between the keyboard and the gamepad.
func test_it_has_a_tab_per_device() -> void:
	var help := ControlsHelp.new()
	add_child_autofree(help)
	help.show_for(InputDevice.Kind.KEYBOARD_MOUSE)
	var tabs : Array = help.find_children("*", "TabStrip", true, false)
	assert_eq(tabs.size(), 1)
	(tabs[0] as TabStrip).selected.emit(&"pad")
	await get_tree().process_frame
	assert_eq(help.showing, InputDevice.Kind.GAMEPAD)
	assert_true(help.visible, "still open")
