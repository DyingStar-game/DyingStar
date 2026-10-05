extends GutTest
## PlayHintsPanel: shows the active lines with their keys, drops what is unbound or learnt, and hides
## when switched off or under a menu.

const PATH := "user://test_play_hints_panel.cfg"

var _panel : PlayHintsPanel
var _owner : Node


func before_each() -> void:
	PlayHints.clear()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	InputMap.add_action(&"test_hint_jump")
	var k := InputEventKey.new()
	k.physical_keycode = KEY_SPACE
	InputMap.action_add_event(&"test_hint_jump", k)
	InputMap.add_action(&"test_hint_unbound")
	_owner = autofree(Node.new())
	_panel = PlayHintsPanel.new()
	_panel.enabled_rule = func() -> bool: return true
	_panel.memory = PlayHintsMemory.new(PATH)
	add_child_autofree(_panel)


func after_each() -> void:
	InputMap.erase_action(&"test_hint_jump")
	InputMap.erase_action(&"test_hint_unbound")
	PlayHints.clear()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


func test_a_line_shows_its_key_and_what_it_does() -> void:
	PlayHints.provide(_owner, &"test", [PlayHints.row(&"test_hint_jump", "%%ACT_JUMP")])
	_panel.refresh()
	assert_eq(_panel.shown().size(), 1)
	assert_eq(_panel.shown()[0]["keys"], InputLabel.for_action(&"test_hint_jump"))
	assert_eq(_panel.shown()[0]["label"], "%%ACT_JUMP")


func test_an_action_with_no_key_is_left_out() -> void:
	PlayHints.provide(_owner, &"test", [PlayHints.row(&"test_hint_unbound", "%%ACT_JUMP")])
	_panel.refresh()
	assert_eq(_panel.shown().size(), 0)


func test_a_rebound_key_shows_as_rebound() -> void:
	PlayHints.provide(_owner, &"test", [PlayHints.row(&"test_hint_jump", "%%ACT_JUMP")])
	var j := InputEventKey.new()
	j.physical_keycode = KEY_J
	InputDevice.rebind(&"test_hint_jump", j)
	_panel.refresh()
	assert_eq(_panel.shown()[0]["keys"], InputLabel.for_event(j))


func test_a_learnt_line_goes_away() -> void:
	PlayHints.provide(_owner, &"test", [PlayHints.row(&"test_hint_jump", "%%ACT_JUMP")])
	for i in PlayHintsMemory.LEARNED_AFTER:
		_panel.memory.note_used(&"test_hint_jump")
	_panel.refresh()
	assert_eq(_panel.shown().size(), 0)


func test_switched_off_or_under_a_menu_it_shows_nothing() -> void:
	PlayHints.provide(_owner, &"test", [PlayHints.row(&"test_hint_jump", "%%ACT_JUMP")])
	_panel.enabled_rule = func() -> bool: return false
	_panel.refresh()
	assert_eq(_panel.shown().size(), 0, "Settings > General switch off")
	_panel.enabled_rule = func() -> bool: return true
	_panel.hidden_rule = func() -> bool: return true
	_panel.refresh()
	assert_eq(_panel.shown().size(), 0, "a menu is open")


func test_at_most_max_rows() -> void:
	var rows : Array = []
	for i in PlayHintsPanel.MAX_ROWS + 3:
		var action := StringName("test_hint_many_%d" % i)
		InputMap.add_action(action)
		var k := InputEventKey.new()
		k.physical_keycode = KEY_A + i
		InputMap.action_add_event(action, k)
		rows.append(PlayHints.row(action, "%%ACT_JUMP"))
	PlayHints.provide(_owner, &"test", rows)
	_panel.refresh()
	assert_eq(_panel.shown().size(), PlayHintsPanel.MAX_ROWS)
	for i in PlayHintsPanel.MAX_ROWS + 3:
		InputMap.erase_action(StringName("test_hint_many_%d" % i))


func test_pressing_a_shown_key_counts_towards_learning_it() -> void:
	PlayHints.provide(_owner, &"test", [PlayHints.row(&"test_hint_jump", "%%ACT_JUMP")])
	_panel.refresh()
	var press := InputEventAction.new()
	press.action = &"test_hint_jump"
	press.pressed = true
	_panel._input(press)
	_panel._input(press)  # within the debounce: one push is one use
	var entry : Array = _panel.memory._config.get_value(PlayHintsMemory.SECTION, "test_hint_jump", [0, 0.0])
	assert_eq(int(entry[0]), 1)
