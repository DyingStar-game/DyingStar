extends GutTest
## AltGr: Windows sends it as a fake LEFT Ctrl press followed by a Right Alt press. The fake Ctrl must
## not read as strafe_down (the EVA body sank while AltGr was held), a real Ctrl must.

const ACTION : StringName = &"test_altgr_ctrl_action"


func before_each() -> void:
	AltGr.reset()
	AltGr.check_keyboard = false  # no real key is down in a test
	InputMap.add_action(ACTION)
	var ctrl := InputEventKey.new()
	ctrl.physical_keycode = KEY_CTRL
	InputMap.action_add_event(ACTION, ctrl)


func after_each() -> void:
	AltGr.reset()
	AltGr.check_keyboard = true
	Input.action_release(ACTION)
	InputMap.erase_action(ACTION)


func _key(keycode: Key, pressed: bool, location: KeyLocation, echo := false) -> InputEventKey:
	var key := InputEventKey.new()
	key.keycode = keycode
	key.location = location
	key.pressed = pressed
	key.echo = echo
	return key


## What Windows sends for one press of AltGr, with Input recording the Ctrl as it really does.
func _press_altgr() -> void:
	AltGr.feed(_key(KEY_CTRL, true, KEY_LOCATION_LEFT))
	Input.action_press(ACTION)
	AltGr.feed(_key(KEY_ALT, true, KEY_LOCATION_RIGHT))


func test_the_fake_ctrl_of_altgr_is_masked() -> void:
	_press_altgr()
	assert_true(AltGr.is_held(), "AltGr held")
	assert_true(AltGr.masks(ACTION), "the Ctrl action is AltGr's doing")
	assert_eq(AltGr.strength(ACTION), 0.0, "and reads as released")
	assert_eq(AltGr.axis(ACTION, &"ui_accept"), 0.0, "so the axis does not move")


func test_releasing_it_clears_the_mask() -> void:
	_press_altgr()
	AltGr.feed(_key(KEY_ALT, false, KEY_LOCATION_RIGHT))
	AltGr.feed(_key(KEY_CTRL, false, KEY_LOCATION_LEFT))
	assert_false(AltGr.is_held(), "released")
	assert_false(AltGr.masks(ACTION), "a later real Ctrl counts again")


func test_a_real_ctrl_held_before_is_not_masked() -> void:
	AltGr.feed(_key(KEY_CTRL, true, KEY_LOCATION_LEFT))
	AltGr.feed(_key(KEY_CTRL, true, KEY_LOCATION_LEFT, true))  # held long enough to repeat
	Input.action_press(ACTION)
	AltGr.feed(_key(KEY_ALT, true, KEY_LOCATION_RIGHT))
	assert_false(AltGr.masks(ACTION), "a Ctrl the player really holds still works")
	assert_eq(AltGr.strength(ACTION), 1.0, "at full strength")


func test_another_key_in_between_means_a_real_ctrl() -> void:
	AltGr.feed(_key(KEY_CTRL, true, KEY_LOCATION_LEFT))
	AltGr.feed(_key(KEY_W, true, KEY_LOCATION_UNSPECIFIED))
	AltGr.feed(_key(KEY_ALT, true, KEY_LOCATION_RIGHT))
	assert_false(AltGr.masks(ACTION), "Ctrl then W then AltGr: the Ctrl is the player's")


func test_the_left_alt_is_not_altgr() -> void:
	AltGr.feed(_key(KEY_CTRL, true, KEY_LOCATION_LEFT))
	AltGr.feed(_key(KEY_ALT, true, KEY_LOCATION_LEFT))
	assert_false(AltGr.is_held(), "Ctrl + left Alt is a shortcut, not AltGr")
	assert_false(AltGr.masks(ACTION), "nothing masked")


func test_an_action_without_ctrl_is_never_masked() -> void:
	_press_altgr()
	assert_false(AltGr.masks(&"ui_accept"), "only actions bound to Ctrl are concerned")


func test_reset_forgets_everything() -> void:
	_press_altgr()
	AltGr.reset()
	assert_false(AltGr.is_held(), "not held")
	assert_false(AltGr.masks(ACTION), "nothing masked")
