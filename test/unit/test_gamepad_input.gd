extends GutTest
## The gamepad beside the keyboard: its bindings saved, captured, recognised by the player's keys,
## named as they are printed on the pad, and kept apart from the keyboard's.

const ACTION := &"test_gamepad_action"


func before_each() -> void:
	InputMap.add_action(ACTION)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_F13
	InputMap.action_add_event(ACTION, key)
	InputMap.action_add_event(ACTION, _button(JOY_BUTTON_A))


func after_each() -> void:
	InputMap.erase_action(ACTION)
	InputDevice.last = InputDevice.Kind.KEYBOARD_MOUSE
	InputDevice.family = InputDevice.Family.XBOX


func _button(index: JoyButton, pressed := true) -> InputEventJoypadButton:
	var b := InputEventJoypadButton.new()
	b.button_index = index
	b.pressed = pressed
	return b


func _axis(axis: JoyAxis, value: float) -> InputEventJoypadMotion:
	var m := InputEventJoypadMotion.new()
	m.axis = axis
	m.axis_value = value
	return m


# --- saved ----------------------------------------------------------------

func test_a_pad_button_and_a_stick_round_trip() -> void:
	var back := InputEventCodec.decode(InputEventCodec.encode(_button(JOY_BUTTON_Y))) as InputEventJoypadButton
	assert_eq(back.button_index, JOY_BUTTON_Y)
	var stick := InputEventCodec.decode(InputEventCodec.encode(_axis(JOY_AXIS_LEFT_Y, -0.8))) as InputEventJoypadMotion
	assert_eq(stick.axis, JOY_AXIS_LEFT_Y)
	assert_eq(stick.axis_value, -1.0, "pushed up, saved as up")


func test_the_file_holds_a_binding_per_device_and_still_reads_the_old_one() -> void:
	assert_eq(SettingsManager.keybindings_of("Alt+T"), {"km": "Alt+T"}, "a file from before the gamepad")
	assert_eq(SettingsManager.keybindings_of({"km": "F", "pad": "joy_button_2", "junk": 1}),
		{"km": "F", "pad": "joy_button_2"})


func test_rebinding_one_device_leaves_the_other_alone() -> void:
	var key := InputEventKey.new()
	key.physical_keycode = KEY_F14
	InputDevice.rebind(ACTION, key)
	assert_eq(InputDevice.bindings(ACTION, InputDevice.Kind.GAMEPAD).size(), 1, "the A button stays")
	assert_eq((InputDevice.bindings(ACTION, InputDevice.Kind.KEYBOARD_MOUSE)[0] as InputEventKey).physical_keycode,
		KEY_F14, "the key is replaced")
	InputDevice.rebind(ACTION, _button(JOY_BUTTON_B))
	assert_eq((InputDevice.bindings(ACTION, InputDevice.Kind.GAMEPAD)[0] as InputEventJoypadButton).button_index,
		JOY_BUTTON_B)
	assert_eq(InputDevice.bindings(ACTION, InputDevice.Kind.KEYBOARD_MOUSE).size(), 1, "the key stays")


# --- captured -------------------------------------------------------------

func test_a_pad_capture_binds_a_button_as_it_goes_down() -> void:
	var capture := BindingCapture.new(InputDevice.Kind.GAMEPAD)
	assert_eq(capture.feed(_button(JOY_BUTTON_X, false)), BindingCapture.Verdict.WAIT, "a release")
	assert_eq(capture.feed(_button(JOY_BUTTON_X)), BindingCapture.Verdict.BIND)
	assert_eq((capture.bound as InputEventJoypadButton).button_index, JOY_BUTTON_X)


func test_a_stick_is_bound_once_pushed_well_past_its_rest() -> void:
	var capture := BindingCapture.new(InputDevice.Kind.GAMEPAD)
	assert_eq(capture.feed(_axis(JOY_AXIS_RIGHT_X, 0.3)), BindingCapture.Verdict.WAIT, "brushed on the way")
	assert_eq(capture.feed(_axis(JOY_AXIS_RIGHT_X, -0.9)), BindingCapture.Verdict.BIND)
	var bound := capture.bound as InputEventJoypadMotion
	assert_eq(bound.axis, JOY_AXIS_RIGHT_X)
	assert_eq(bound.axis_value, -1.0, "and which way")


func test_a_capture_listens_to_its_own_device_only() -> void:
	var key := InputEventKey.new()
	key.physical_keycode = KEY_X
	key.pressed = true
	assert_eq(BindingCapture.new(InputDevice.Kind.GAMEPAD).feed(key), BindingCapture.Verdict.WAIT,
		"the pad column takes no key")
	assert_eq(BindingCapture.new().feed(_button(JOY_BUTTON_A)), BindingCapture.Verdict.WAIT,
		"the keyboard column takes no pad button")


# --- played ---------------------------------------------------------------

## InputCombo asked a pad press for its modifiers, found none, and answered no: every key the player
## code reads through it would have ignored the gamepad.
func test_a_pad_button_triggers_its_action() -> void:
	assert_true(InputCombo.pressed(_button(JOY_BUTTON_A), ACTION))
	assert_false(InputCombo.pressed(_button(JOY_BUTTON_B), ACTION), "another button does not")


# --- named ----------------------------------------------------------------

func test_buttons_are_named_as_printed_on_the_pad() -> void:
	assert_eq(InputLabel.pad_button_name(JOY_BUTTON_A, InputDevice.Family.XBOX), "A")
	assert_eq(InputLabel.pad_button_name(JOY_BUTTON_LEFT_SHOULDER, InputDevice.Family.PLAYSTATION), "L1")
	assert_eq(InputLabel.pad_button_name(JOY_BUTTON_A, InputDevice.Family.NINTENDO), "B",
		"the bottom button of a Nintendo pad says B")
	assert_eq(InputLabel.pad_axis_name(JOY_AXIS_TRIGGER_RIGHT, 1.0, InputDevice.Family.XBOX), "RT")
	assert_string_contains(InputLabel.pad_axis_name(JOY_AXIS_LEFT_X, -1.0, InputDevice.Family.XBOX), "LS")
	assert_string_contains(InputLabel.pad_button_name(12, InputDevice.Family.GENERIC), "13",
		"a flight stick's buttons by number, counted from one")


func test_the_hud_names_the_device_in_the_players_hands() -> void:
	InputDevice.feed(_button(JOY_BUTTON_START))
	assert_eq(InputDevice.last, InputDevice.Kind.GAMEPAD)
	assert_eq(InputLabel.for_action(ACTION), "A", "on the gamepad, the button")
	var key := InputEventKey.new()
	key.pressed = true
	InputDevice.feed(key)
	assert_eq(InputLabel.for_action(ACTION), InputLabel.for_event(InputDevice.bindings(ACTION,
			InputDevice.Kind.KEYBOARD_MOUSE)[0]), "back on the keyboard, the key")


func test_a_resting_stick_does_not_take_the_hud_from_the_keyboard() -> void:
	InputDevice.feed(_axis(JOY_AXIS_LEFT_X, 0.1))
	assert_eq(InputDevice.last, InputDevice.Kind.KEYBOARD_MOUSE)


func test_the_family_comes_from_the_pads_name() -> void:
	assert_eq(InputDevice.family_of("PS5 Controller", true), InputDevice.Family.PLAYSTATION)
	assert_eq(InputDevice.family_of("Xbox Series Controller", true), InputDevice.Family.XBOX)
	assert_eq(InputDevice.family_of("Nintendo Switch Pro Controller", true), InputDevice.Family.NINTENDO)
	assert_eq(InputDevice.family_of("Thrustmaster T.16000M", false), InputDevice.Family.GENERIC,
		"unknown to Godot: numbered")
