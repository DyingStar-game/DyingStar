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
	InputMap.add_action(&"test_hint_more")
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	InputMap.action_add_event(&"test_hint_more", m)
	_owner = autofree(Node.new())
	_panel = PlayHintsPanel.new()
	_panel.enabled_rule = func() -> bool: return true
	_panel.memory = PlayHintsMemory.new(PATH)
	add_child_autofree(_panel)


func after_each() -> void:
	InputMap.erase_action(&"test_hint_jump")
	InputMap.erase_action(&"test_hint_unbound")
	InputMap.erase_action(&"test_hint_more")
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


## The speed limiter waits for the wheel: a context shows its level-1 lines once its level-0 ones are learnt.
func test_the_next_level_shows_once_the_basics_are_learnt() -> void:
	PlayHints.provide(_owner, &"test", [PlayHints.row(&"test_hint_jump", "%%ACT_JUMP"),
			PlayHints.row(&"test_hint_more", "%%ACT_SPRINT", 1)])
	_panel.refresh()
	assert_eq(_labels(), ["%%ACT_JUMP"], "the basics first")
	for i in PlayHintsMemory.LEARNED_AFTER:
		_panel.memory.note_used(&"test_hint_jump")
	_panel.refresh()
	assert_eq(_labels(), ["%%ACT_SPRINT"], "then what comes next")


## A basic with nothing to press on this device holds nothing back: it cannot be learnt here.
func test_an_unbound_basic_does_not_hold_the_next_level_back() -> void:
	PlayHints.provide(_owner, &"test", [PlayHints.row(&"test_hint_unbound", "%%ACT_JUMP"),
			PlayHints.row(&"test_hint_more", "%%ACT_SPRINT", 1)])
	_panel.refresh()
	assert_eq(_labels(), ["%%ACT_SPRINT"])


## Levels count per context: learning the wheel says nothing about the drill.
func test_each_context_has_its_own_levels() -> void:
	PlayHints.provide(_owner, &"a", [PlayHints.row(&"test_hint_jump", "%%ACT_JUMP")])
	PlayHints.provide(_owner, &"b", [PlayHints.row(&"test_hint_more", "%%ACT_SPRINT", 1)])
	_panel.refresh()
	assert_eq(_labels(), ["%%ACT_JUMP", "%%ACT_SPRINT"])


## The star map's own panel shows the chart's lines only.
func test_a_panel_can_keep_to_some_contexts() -> void:
	PlayHints.provide(_owner, &"star_map", [PlayHints.row(&"test_hint_jump", "%%ACT_JUMP")])
	PlayHints.provide(_owner, &"on_foot", [PlayHints.row(&"test_hint_more", "%%ACT_SPRINT")])
	_panel.contexts = [&"star_map"]
	_panel.refresh()
	assert_eq(_labels(), ["%%ACT_JUMP"])


func _labels() -> Array:
	return _panel.shown().map(func(r: Dictionary) -> String: return str(r["label"]))
