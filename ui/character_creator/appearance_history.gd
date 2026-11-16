class_name AppearanceHistory
extends RefCounted

## Undo and redo for the character creator: the looks it went through, as their replicated strings
## (CharacterAppearance.encode, ~100 bytes each), at most LIMIT steps back.

## Steps kept back.
const LIMIT: int = 100

var _states: PackedStringArray = []
var _at: int = -1


## Start over from [param state] (the look the creator opened with).
func reset(state: String) -> void:
	_states = [state]
	_at = 0


## Record [param state] as the next step, dropping whatever had been undone. Nothing when it is the
## current one (a slider let go where it was).
func push(state: String) -> void:
	if _at >= 0 and _states[_at] == state:
		return
	_states = _states.slice(0, _at + 1)
	_states.append(state)
	if _states.size() > LIMIT + 1:
		_states = _states.slice(_states.size() - LIMIT - 1)
	_at = _states.size() - 1


func can_undo() -> bool:
	return _at > 0


func can_redo() -> bool:
	return _at >= 0 and _at < _states.size() - 1


## One step back: the look before, or "" when there is none.
func undo() -> String:
	if not can_undo():
		return ""
	_at -= 1
	return _states[_at]


## One step forward again: the look after, or "" when there is none.
func redo() -> String:
	if not can_redo():
		return ""
	_at += 1
	return _states[_at]


func current() -> String:
	return _states[_at] if _at >= 0 else ""
