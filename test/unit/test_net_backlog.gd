extends GutTest
## NetBacklog: what Horizon sent, handled in arrival order a time budget a frame.

var _seen: Array = []


func _route(event: Dictionary) -> bool:
	_seen.append(event["n"])
	return not event.get("error", false)


func _slow_route(event: Dictionary) -> bool:
	OS.delay_usec(2000)
	return _route(event)


func before_each() -> void:
	_seen = []


func test_a_light_frame_handles_everything_in_order() -> void:
	var backlog := NetBacklog.new()
	for n in 5:
		backlog.push({"n": n})
	assert_true(backlog.drain(_route, 100000))
	assert_eq(_seen, [0, 1, 2, 3, 4])
	assert_eq(backlog.size(), 0)


func test_a_burst_waits_for_the_next_frames_in_order() -> void:
	var backlog := NetBacklog.new()
	for n in 10:
		backlog.push({"n": n})
	backlog.drain(_slow_route, 5000)  # 2 ms each: three fit in 5 ms
	assert_between(_seen.size(), 1, 4, "the budget stops the frame")
	var frames := 1
	while backlog.size() > 0:
		backlog.drain(_slow_route, 5000)
		frames += 1
	assert_eq(_seen, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], "the same events, in the same order")
	assert_gt(frames, 2)


func test_an_event_over_the_budget_still_moves() -> void:
	var backlog := NetBacklog.new()
	backlog.push({"n": 0})
	backlog.push({"n": 1})
	backlog.drain(_slow_route, 0)
	assert_eq(_seen, [0], "one a frame at least")
	backlog.drain(_slow_route, 0)
	assert_eq(_seen, [0, 1])


func test_an_error_drops_what_is_left() -> void:
	var backlog := NetBacklog.new()
	backlog.push({"n": 0})
	backlog.push({"n": 1, "error": true})
	backlog.push({"n": 2})
	assert_false(backlog.drain(_route, 100000))
	assert_eq(_seen, [0, 1])
	assert_eq(backlog.size(), 0)


func test_events_pushed_while_waiting_come_after() -> void:
	var backlog := NetBacklog.new()
	for n in NetBacklog.COMPACT_AT + 10:
		backlog.push({"n": n})
	backlog.drain(_route, 0)
	while _seen.size() < NetBacklog.COMPACT_AT + 5:
		backlog.drain(_route, 0)
	backlog.push({"n": -1})
	while backlog.size() > 0:
		backlog.drain(_route, 100000)
	assert_eq(_seen.size(), NetBacklog.COMPACT_AT + 11)
	assert_eq(_seen[-1], -1, "after the compaction too")
	assert_eq(_seen[NetBacklog.COMPACT_AT + 9], NetBacklog.COMPACT_AT + 9)


## What an event unblocks goes next, in the order it was pushed, before what was already waiting.
func test_what_an_event_unblocks_goes_next() -> void:
	var backlog := NetBacklog.new()
	var unblocking := func(event: Dictionary) -> bool:
		_seen.append(event["n"])
		if event["n"] == 0:
			backlog.push_next({"n": 10})
			backlog.push_next({"n": 11})
		return true
	backlog.push({"n": 0})
	backlog.push({"n": 1})
	backlog.drain(unblocking, 100000)
	assert_eq(_seen, [0, 10, 11, 1])


func test_unblocked_between_frames_goes_first() -> void:
	var backlog := NetBacklog.new()
	backlog.push({"n": 0})
	backlog.push({"n": 1})
	backlog.drain(_route, 0)
	backlog.push_next({"n": 10})
	backlog.push_next({"n": 11})
	backlog.drain(_route, 100000)
	assert_eq(_seen, [0, 10, 11, 1])
