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
