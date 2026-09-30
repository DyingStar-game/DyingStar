class_name InputCombo
extends RefCounted
## Which action a key press is FOR, when several are bound to the same key with different modifiers.
##
## Godot fires an action as soon as the modifiers it asks for are held, whatever else is held with
## them: Alt+L fires the action bound to Alt+L and the one bound to a plain L. The player code used to
## sort that out key by key, testing Alt by hand around each shared key — which only held for the
## default bindings, and silenced an action the moment a player moved it off its Alt.
##
## One rule instead: on a press, the binding that names the MOST of the held modifiers wins, and an
## action bound less precisely to the same key stays quiet. Two actions bound alike both fire, as the
## torch and the head lights do on L.
##
## For presses handled as events. Held keys that are polled (moving, sprinting, braking) do not come
## here: holding Ctrl to sink must not stop you walking.


## Is [param event] a press of [param action], and of no action bound more precisely to that key?
static func pressed(event: InputEvent, action: StringName, allow_echo: bool = false) -> bool:
	if not event.is_action_pressed(action, allow_echo):
		return false
	return wins(event, action)


## Does [param action] own [param event]'s key, among all the actions bound to it?
static func wins(event: InputEvent, action: StringName) -> bool:
	var mine: int = _precision(event, action)
	if mine < 0:
		return false
	for other: StringName in InputMap.get_actions():
		if other != action and _precision(event, other) > mine:
			return false
	return true


## How many modifiers the best binding of [param action] for this key asks for, or -1 when none of its
## bindings answers this event.
static func _precision(event: InputEvent, action: StringName) -> int:
	var held := event as InputEventWithModifiers
	if held == null or not InputMap.has_action(action):
		return -1
	var held_mask: int = held.get_modifiers_mask()
	var best: int = -1
	for bound: InputEvent in InputMap.action_get_events(action):
		if not _same_input(bound, event):
			continue
		var asked: int = (bound as InputEventWithModifiers).get_modifiers_mask()
		if (asked & held_mask) != asked:
			continue
		best = maxi(best, _bits(asked))
	return best


static func _same_input(bound: InputEvent, event: InputEvent) -> bool:
	if bound is InputEventKey and event is InputEventKey:
		var b: InputEventKey = bound
		var e: InputEventKey = event
		if b.physical_keycode != KEY_NONE:
			return b.physical_keycode == e.physical_keycode
		return b.keycode != KEY_NONE and b.keycode == e.keycode
	if bound is InputEventMouseButton and event is InputEventMouseButton:
		return (bound as InputEventMouseButton).button_index == (event as InputEventMouseButton).button_index
	return false


static func _bits(mask: int) -> int:
	var count: int = 0
	for flag: int in [KEY_MASK_CTRL, KEY_MASK_ALT, KEY_MASK_SHIFT, KEY_MASK_META]:
		if mask & flag:
			count += 1
	return count
