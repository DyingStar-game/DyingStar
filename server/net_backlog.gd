class_name NetBacklog
extends RefCounted
## The events the client received from Horizon, handled in the order they came, a time budget a frame.
##
## A zone entry brings hundreds of objects in one burst — the village, its buildings, its props — and
## handling them all in the frame they arrived froze the game: 367 creations, 1.25 s, in one frame
## (2026-10-22). Queued here, they are handled in arrival order until the frame's budget is spent and
## the rest waits for the next frame: the same events, the same order, spread over frames. A frame
## with a few events handles them all at once, as before.
##
## One event is never split: an event that costs more than the budget (a planet) still takes its frame.
## At least one is handled a frame, so a stream heavier than the budget still moves. What an event
## unblocks — the objects that were waiting for it as their parent — goes next (push_next) instead of
## being built inside it: a planet arriving after its 360 village objects built them all in its frame.

## Past this many handled events at the head, the array is compacted (a slice instead of a pop_front
## each, which moves the whole array).
const COMPACT_AT := 1024

var _events: Array[Dictionary] = []
var _head: int = 0
## Where push_next inserts: right after the event being handled, after what it already pushed.
var _insert_at: int = 0


func push(event: Dictionary) -> void:
	_events.append(event)


## [param event] handled next, before what was waiting: something the event being handled unblocked.
## Several calls keep their order.
func push_next(event: Dictionary) -> void:
	_events.insert(_insert_at, event)
	_insert_at += 1


## Events waiting.
func size() -> int:
	return _events.size() - _head


## Hand the waiting events to [param route] (event -> bool, false to stop: the connection was closed
## on an error), in order, until [param budget_usec] have passed. False when [param route] asked to
## stop: what was left is dropped.
func drain(route: Callable, budget_usec: int) -> bool:
	var deadline: int = Time.get_ticks_usec() + budget_usec
	while _head < _events.size():
		var event: Dictionary = _events[_head]
		_head += 1
		_insert_at = _head
		if not route.call(event):
			clear()
			return false
		if Time.get_ticks_usec() >= deadline:
			break
	if _head >= _events.size():
		clear()
	elif _head >= COMPACT_AT:
		_events = _events.slice(_head)
		_head = 0
	_insert_at = _head
	return true


func clear() -> void:
	_events.clear()
	_head = 0
	_insert_at = 0
