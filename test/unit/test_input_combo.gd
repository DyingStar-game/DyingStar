extends GutTest
## InputCombo: when two actions share a key and differ by their modifiers, a press goes to the one
## bound the most precisely. Godot alone fires both on Ctrl+E — the one bound to Ctrl+E and the one
## bound to E.

const PLAIN := &"test_combo_plain"
const WITH_CTRL := &"test_combo_ctrl"
const TWIN := &"test_combo_twin"


func before_each() -> void:
	for action: StringName in [PLAIN, WITH_CTRL, TWIN]:
		InputMap.add_action(action)
	InputMap.action_add_event(PLAIN, _key(KEY_F13))
	InputMap.action_add_event(TWIN, _key(KEY_F13))
	InputMap.action_add_event(WITH_CTRL, _key(KEY_F13, true))


func after_each() -> void:
	for action: StringName in [PLAIN, WITH_CTRL, TWIN]:
		InputMap.erase_action(action)


func _key(physical: Key, ctrl := false, shift := false) -> InputEventKey:
	var k := InputEventKey.new()
	k.physical_keycode = physical
	k.pressed = true
	k.ctrl_pressed = ctrl
	k.shift_pressed = shift
	return k


func test_the_bare_key_goes_to_the_plain_binding() -> void:
	var press := _key(KEY_F13)
	assert_true(InputCombo.pressed(press, PLAIN))
	assert_false(InputCombo.pressed(press, WITH_CTRL), "Ctrl is not held")


func test_the_combination_goes_to_the_precise_binding_alone() -> void:
	var press := _key(KEY_F13, true)
	assert_true(InputCombo.pressed(press, WITH_CTRL))
	assert_true(press.is_action_pressed(PLAIN), "Godot alone would fire the plain one too")
	assert_false(InputCombo.pressed(press, PLAIN), "the plain binding stays quiet")


func test_a_modifier_nobody_asked_for_changes_nothing() -> void:
	assert_true(InputCombo.pressed(_key(KEY_F13, false, true), PLAIN),
		"Shift+key with no Shift binding on that key is still the key")


func test_two_actions_bound_alike_both_fire() -> void:
	var press := _key(KEY_F13)
	assert_true(InputCombo.pressed(press, PLAIN) and InputCombo.pressed(press, TWIN),
		"as the torch and the head lights do on L")


func test_a_release_is_not_a_press() -> void:
	var release := _key(KEY_F13)
	release.pressed = false
	assert_false(InputCombo.pressed(release, PLAIN))


func test_mouse_buttons_follow_the_same_rule() -> void:
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_MIDDLE
	var alt_wheel := wheel.duplicate() as InputEventMouseButton
	alt_wheel.alt_pressed = true
	InputMap.action_add_event(PLAIN, wheel)
	InputMap.action_add_event(WITH_CTRL, alt_wheel)
	var press := alt_wheel.duplicate() as InputEventMouseButton
	press.pressed = true
	assert_true(InputCombo.pressed(press, WITH_CTRL))
	assert_false(InputCombo.pressed(press, PLAIN))
