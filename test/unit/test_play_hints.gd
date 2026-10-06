extends GutTest
## PlayHints, the registry every feature offers its play hints to.


func before_each() -> void:
	PlayHints.clear()


func after_all() -> void:
	PlayHints.clear()


func _labels(rows: Array[Dictionary]) -> Array:
	return rows.map(func(r: Dictionary) -> String: return str(r["label"]))


func test_a_row_takes_the_controls_page_label_by_default() -> void:
	assert_eq(PlayHints.row(&"jump")["label"], "%%ACT_JUMP")
	assert_eq(PlayHints.row(&"jump", "%%HINT_DRIVE")["label"], "%%HINT_DRIVE", "unless given one")
	assert_eq(PlayHints.row([&"move_forward", &"move_back"], "%%HELP_MOVE")["actions"],
			[&"move_forward", &"move_back"] as Array[StringName])


func test_offered_lines_show_until_withdrawn() -> void:
	var owner := Node.new()
	PlayHints.provide(owner, &"test", [PlayHints.row(&"jump")])
	assert_eq(_labels(PlayHints.active()), ["%%ACT_JUMP"])
	PlayHints.withdraw(owner, &"test")
	assert_eq(PlayHints.active().size(), 0)
	owner.free()


func test_lines_go_with_their_owner() -> void:
	var owner := Node.new()
	PlayHints.provide(owner, &"test", [PlayHints.row(&"jump")])
	owner.free()
	assert_eq(PlayHints.active().size(), 0, "nothing to clean up by hand")


func test_when_decides_whether_they_show() -> void:
	var owner := Node.new()
	var on := [false]
	PlayHints.provide(owner, &"test", [PlayHints.row(&"jump")], func() -> bool: return on[0])
	assert_eq(PlayHints.active().size(), 0)
	on[0] = true
	assert_eq(PlayHints.active().size(), 1)
	owner.free()


func test_higher_priority_first_and_each_action_once() -> void:
	var owner := Node.new()
	PlayHints.provide(owner, &"low", [PlayHints.row(&"jump"), PlayHints.row(&"exit")], Callable(), 0)
	PlayHints.provide(owner, &"high", [PlayHints.row(&"exit", "%%HUD_DROP")], Callable(), 10)
	assert_eq(_labels(PlayHints.active()), ["%%HUD_DROP", "%%ACT_JUMP"], "exit listed once, by the higher context")
	owner.free()


func test_offering_the_same_context_again_replaces_it() -> void:
	var owner := Node.new()
	PlayHints.provide(owner, &"test", [PlayHints.row(&"jump")])
	PlayHints.provide(owner, &"test", [PlayHints.row(&"sprint")])
	assert_eq(_labels(PlayHints.active()), ["%%ACT_SPRINT"])
	owner.free()


func test_the_keys_of_a_line_are_its_bindings_once_each() -> void:
	InputMap.add_action(&"test_hint_a")
	InputMap.add_action(&"test_hint_b")
	var k := InputEventKey.new()
	k.keycode = KEY_K
	InputMap.action_add_event(&"test_hint_a", k)
	InputMap.action_add_event(&"test_hint_b", k)
	assert_eq(PlayHints.keys_of([&"test_hint_a", &"test_hint_b"], InputDevice.Kind.KEYBOARD_MOUSE), "K")
	assert_eq(PlayHints.keys_of([&"no_such_action"], InputDevice.Kind.KEYBOARD_MOUSE), "")
	InputMap.erase_action(&"test_hint_a")
	InputMap.erase_action(&"test_hint_b")


func test_a_row_is_a_basic_unless_given_a_level() -> void:
	assert_eq(PlayHints.row(&"jump")["level"], 0)
	assert_eq(PlayHints.row(&"jump", "", 1)["level"], 1)
	PlayHints.provide(self, &"test", [PlayHints.row(&"sprint", "", 2)])
	assert_eq(PlayHints.active()[0]["level"], 2, "the level travels to the panel")


## A line grouping alternatives (the wheel's zoom steps, the pad's held triggers) names only what the
## device in hand has: the mouse is never offered to a pad player while the pad has one of them.
func test_the_keys_are_the_device_in_hand_s_when_it_has_any() -> void:
	InputMap.add_action(&"test_hint_mouse")
	InputMap.add_action(&"test_hint_pad")
	var k := InputEventKey.new()
	k.keycode = KEY_K
	InputMap.action_add_event(&"test_hint_mouse", k)
	var b := InputEventJoypadButton.new()
	b.button_index = JOY_BUTTON_A
	InputMap.action_add_event(&"test_hint_pad", b)
	var both : Array = [&"test_hint_mouse", &"test_hint_pad"]
	assert_eq(PlayHints.keys_of(both, InputDevice.Kind.KEYBOARD_MOUSE), ControlsHelpRows.name_of(k))
	assert_eq(PlayHints.keys_of(both, InputDevice.Kind.GAMEPAD), ControlsHelpRows.name_of(b))
	assert_eq(PlayHints.keys_of([&"test_hint_mouse"], InputDevice.Kind.GAMEPAD), ControlsHelpRows.name_of(k),
			"none on the pad at all: the keyboard's, rather than nothing")
	InputMap.erase_action(&"test_hint_mouse")
	InputMap.erase_action(&"test_hint_pad")


## "Alt + Molette haut Alt + Molette bas" read as two keys pressed together; said once, the shared words
## leave what differs side by side.
func test_the_words_a_line_s_keys_share_are_said_once() -> void:
	assert_eq(PlayHints.compact(PackedStringArray(["Alt + Molette haut", "Alt + Molette bas"])),
			"Alt + Molette haut/bas")
	assert_eq(PlayHints.compact(PackedStringArray(["Molette haut", "Molette bas", "Num +", "Num -"])),
			"Molette haut/bas Num +/-")
	assert_eq(PlayHints.compact(PackedStringArray(["Z", "Q", "S", "D"])), "Z Q S D", "nothing shared")
	assert_eq(PlayHints.compact(PackedStringArray(["Espace"])), "Espace")
