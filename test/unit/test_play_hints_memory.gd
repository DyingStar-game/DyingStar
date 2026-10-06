extends GutTest
## PlayHintsMemory: a hint is learnt after a few uses, and comes back after a long time away.

const PATH := "user://test_play_hints_memory.cfg"

var _clock : Array = [1000000.0]


func _memory() -> PlayHintsMemory:
	var m := PlayHintsMemory.new(PATH)
	m.now = func() -> float: return _clock[0]
	return m


func before_each() -> void:
	_clock[0] = 1000000.0
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


func after_all() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


func test_learnt_after_a_few_uses() -> void:
	var m := _memory()
	for i in PlayHintsMemory.LEARNED_AFTER - 1:
		m.note_used(&"jump")
	assert_false(m.is_learned([&"jump"]))
	m.note_used(&"jump")
	assert_true(m.is_learned([&"jump"]))


func test_the_uses_of_a_line_add_up_over_its_actions() -> void:
	var m := _memory()
	m.note_used(&"move_forward")
	m.note_used(&"move_left")
	m.note_used(&"move_back")
	assert_true(m.is_learned([&"move_forward", &"move_left", &"move_back", &"move_right"]))


func test_kept_from_one_session_to_the_next() -> void:
	var m := _memory()
	for i in PlayHintsMemory.LEARNED_AFTER:
		m.note_used(&"jump")
	assert_true(_memory().is_learned([&"jump"]), "read back from the file")


func test_back_after_a_long_time_away() -> void:
	var m := _memory()
	for i in PlayHintsMemory.LEARNED_AFTER:
		m.note_used(&"jump")
	_clock[0] += PlayHintsMemory.RELEARN_AFTER_S + 1.0
	assert_false(m.is_learned([&"jump"]), "a week without it: shown again")
	m.note_used(&"jump")
	assert_true(m.is_learned([&"jump"]), "until it is used again")


func test_reset_shows_everything_again() -> void:
	var m := _memory()
	for i in PlayHintsMemory.LEARNED_AFTER:
		m.note_used(&"jump")
	m.reset()
	assert_false(m.is_learned([&"jump"]))
	assert_false(_memory().is_learned([&"jump"]), "the file is forgotten too")
