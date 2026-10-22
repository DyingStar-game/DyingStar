extends GutTest
## Quitting leaves the voice room first and waits for it (LiveKitAudio.rooms_left), but never longer than
## its timeout: a room that never answers must not hold the game open.

const LIVEKIT := preload("res://scenes/audio/livekit.gd")


func after_each() -> void:
	LIVEKIT._leaving.clear()


func test_nothing_to_leave_quits_at_once() -> void:
	var start: int = Time.get_ticks_msec()
	await LIVEKIT.rooms_left(get_tree(), 2.0)
	assert_lt(Time.get_ticks_msec() - start, 100, "no room: no wait")


func test_a_room_that_never_answers_waits_the_timeout_only() -> void:
	LIVEKIT._leaving.append(RefCounted.new())
	var start: int = Time.get_ticks_msec()
	await LIVEKIT.rooms_left(get_tree(), 0.2)
	var waited: int = Time.get_ticks_msec() - start
	assert_gte(waited, 200, "waits for it")
	assert_lt(waited, 1000, "but not past the timeout")


func test_the_wait_ends_as_the_room_leaves() -> void:
	var room := RefCounted.new()
	LIVEKIT._leaving.append(room)
	get_tree().create_timer(0.1).timeout.connect(func() -> void: LIVEKIT._leaving.erase(room))
	var start: int = Time.get_ticks_msec()
	await LIVEKIT.rooms_left(get_tree(), 2.0)
	assert_lt(Time.get_ticks_msec() - start, 1000, "left: the game quits")
