class_name BindingCapture
extends RefCounted
## What the controls page binds while it listens for "the next key": fed every event, it answers wait,
## or bind THIS.
##
## The page used to bind the first key event it saw. To type Alt+X you press Alt first, and that press
## is a key event like any other: the action was bound to Alt alone and the X never arrived. So a
## modifier going DOWN only waits. It is bound on its own when it comes back UP with nothing pressed
## in between — sprint sits on a bare Shift, the EVA descent on a bare Ctrl, and both must stay
## bindable.
##
## Kept apart from the page, and without a node, so the rules can be tested with plain events.

enum Verdict { WAIT, BIND }

const MODIFIERS: Array[Key] = [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]

## What to bind, once [method feed] has answered BIND. Built fresh, never the live event: a modifier
## key reports its own flag as held on some platforms, which saved a bare Alt as "Alt+Alt".
var bound: InputEvent = null

## Modifier keys currently down, as this capture saw them go down.
var _held: Array[Key] = []
## More than one modifier has been down at once since the last time none was: releasing one of them is
## then somebody giving up on a combination, not asking for that modifier alone.
var _several: bool = false


func feed(event: InputEvent) -> Verdict:
	var mouse := event as InputEventMouseButton
	if mouse != null:
		if not mouse.pressed:
			return Verdict.WAIT
		var button := InputEventMouseButton.new()
		button.button_index = mouse.button_index
		_copy_modifiers(mouse, button)
		bound = button
		return Verdict.BIND
	var key := event as InputEventKey
	if key == null or key.echo:
		return Verdict.WAIT
	var code: Key = key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
	if code == KEY_NONE:
		return Verdict.WAIT
	if code in MODIFIERS:
		return _feed_modifier(code, key.pressed)
	if not key.pressed:
		return Verdict.WAIT
	var made := InputEventKey.new()
	made.physical_keycode = code
	_copy_modifiers(key, made)
	bound = made
	return Verdict.BIND


func _feed_modifier(code: Key, pressed: bool) -> Verdict:
	if pressed:
		if not _held.has(code):
			_held.append(code)
		_several = _several or _held.size() > 1
		return Verdict.WAIT
	var was_alone: bool = _held.has(code) and not _several
	_held.erase(code)
	if _held.is_empty():
		_several = false
	if not was_alone:
		return Verdict.WAIT
	var made := InputEventKey.new()
	made.physical_keycode = code
	bound = made
	return Verdict.BIND


static func _copy_modifiers(from: InputEventWithModifiers, to: InputEventWithModifiers) -> void:
	to.ctrl_pressed = from.ctrl_pressed
	to.alt_pressed = from.alt_pressed
	to.shift_pressed = from.shift_pressed
	to.meta_pressed = from.meta_pressed
