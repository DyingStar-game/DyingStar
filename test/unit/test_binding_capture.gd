extends GutTest
## BindingCapture: what the controls page binds out of the keys pressed while it listens. A modifier
## going down waits for the key it is held for — the page bound Alt alone before Alt+X could be typed —
## and any mouse button counts, the wheel click included.

var _capture: BindingCapture


func before_each() -> void:
	_capture = BindingCapture.new()


func _key(physical: Key, pressed := true, ctrl := false, alt := false, shift := false) -> InputEventKey:
	var k := InputEventKey.new()
	k.physical_keycode = physical
	k.pressed = pressed
	k.ctrl_pressed = ctrl
	k.alt_pressed = alt
	k.shift_pressed = shift
	return k


func _mouse(index: MouseButton, pressed := true, ctrl := false) -> InputEventMouseButton:
	var m := InputEventMouseButton.new()
	m.button_index = index
	m.pressed = pressed
	m.ctrl_pressed = ctrl
	return m


func test_a_plain_key_is_bound_as_it_goes_down() -> void:
	assert_eq(_capture.feed(_key(KEY_X)), BindingCapture.Verdict.BIND)
	var bound := _capture.bound as InputEventKey
	assert_eq(bound.physical_keycode, KEY_X, "the key pressed")
	assert_eq(bound.get_modifiers_mask(), 0, "no modifier invented")


func test_alt_then_x_is_alt_x_not_alt() -> void:
	# The modifier's own press carries its own flag on Windows; fed as such.
	assert_eq(_capture.feed(_key(KEY_ALT, true, false, true)), BindingCapture.Verdict.WAIT,
		"Alt going down is not yet a binding")
	assert_eq(_capture.feed(_key(KEY_X, true, false, true)), BindingCapture.Verdict.BIND)
	var bound := _capture.bound as InputEventKey
	assert_eq(bound.physical_keycode, KEY_X, "the key, not the modifier")
	assert_true(bound.alt_pressed, "with its Alt")
	assert_false(bound.ctrl_pressed or bound.shift_pressed, "and nothing else")


func test_two_modifiers_and_a_key() -> void:
	_capture.feed(_key(KEY_CTRL, true, true))
	_capture.feed(_key(KEY_SHIFT, true, true, false, true))
	assert_eq(_capture.feed(_key(KEY_X, true, true, false, true)), BindingCapture.Verdict.BIND)
	var bound := _capture.bound as InputEventKey
	assert_true(bound.ctrl_pressed and bound.shift_pressed, "both are kept")


func test_a_modifier_pressed_and_released_alone_is_bound_bare() -> void:
	_capture.feed(_key(KEY_SHIFT, true, false, false, true))
	assert_eq(_capture.feed(_key(KEY_SHIFT, false)), BindingCapture.Verdict.BIND,
		"sprint sits on a bare Shift: it must stay bindable")
	var bound := _capture.bound as InputEventKey
	assert_eq(bound.physical_keycode, KEY_SHIFT)
	assert_eq(bound.get_modifiers_mask(), 0, "Shift, not Shift+Shift")


func test_giving_up_on_a_combination_binds_nothing() -> void:
	_capture.feed(_key(KEY_CTRL, true, true))
	_capture.feed(_key(KEY_SHIFT, true, true, false, true))
	assert_eq(_capture.feed(_key(KEY_SHIFT, false, true)), BindingCapture.Verdict.WAIT)
	assert_eq(_capture.feed(_key(KEY_CTRL, false)), BindingCapture.Verdict.WAIT,
		"two modifiers let go are not a request for either")
	_capture.feed(_key(KEY_ALT, true, false, true))
	assert_eq(_capture.feed(_key(KEY_ALT, false)), BindingCapture.Verdict.BIND,
		"and the capture is ready for a lone modifier again")


func test_the_wheel_click_is_bound() -> void:
	assert_eq(_capture.feed(_mouse(MOUSE_BUTTON_MIDDLE)), BindingCapture.Verdict.BIND)
	assert_eq((_capture.bound as InputEventMouseButton).button_index, MOUSE_BUTTON_MIDDLE)


func test_a_mouse_button_keeps_the_modifier_held_with_it() -> void:
	_capture.feed(_key(KEY_CTRL, true, true))
	assert_eq(_capture.feed(_mouse(MOUSE_BUTTON_XBUTTON1, true, true)), BindingCapture.Verdict.BIND)
	var bound := _capture.bound as InputEventMouseButton
	assert_eq(bound.button_index, MOUSE_BUTTON_XBUTTON1)
	assert_true(bound.ctrl_pressed)


func test_releases_repeats_and_other_events_wait() -> void:
	assert_eq(_capture.feed(_key(KEY_X, false)), BindingCapture.Verdict.WAIT, "a key coming up")
	assert_eq(_capture.feed(_mouse(MOUSE_BUTTON_LEFT, false)), BindingCapture.Verdict.WAIT,
		"the release of the click that opened the capture")
	var echo := _key(KEY_X)
	echo.echo = true
	assert_eq(_capture.feed(echo), BindingCapture.Verdict.WAIT, "a key repeating")
	assert_eq(_capture.feed(InputEventMouseMotion.new()), BindingCapture.Verdict.WAIT, "the pointer moving")
	assert_null(_capture.bound)
