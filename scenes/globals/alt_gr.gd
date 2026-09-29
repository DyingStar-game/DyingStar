class_name AltGr
extends RefCounted
## The AltGr key (RIGHT Alt): whether it is held, and the fake Ctrl Windows sends with it.
##
## On Windows, AltGr arrives as a LEFT Ctrl press immediately followed by a Right Alt press. Swallowing
## the events does not help: Input has already recorded the Ctrl before any node sees it, so every
## POLLED Ctrl action (strafe_down, by default) reads as held — the EVA body sank while AltGr was held
## for the graphics panel. Polled reads of such actions go through strength() / axis() here instead.
##
## Fed with EVERY window event from Globals (Window.window_input, which fires before any node's
## _input: a panel swallowing the key cannot hide it from us). Static, so there is one answer.
##
## A real left Ctrl held when AltGr goes down is masked too: Windows gives no way to tell them apart.
## On Linux and macOS no fake Ctrl is sent, so nothing is ever masked.

static var _held : bool = false
## The Ctrl currently down is the one Windows made up for AltGr.
static var _ctrl_is_fake : bool = false
## The previous key event was a left Ctrl going down (what the fake one looks like, just before AltGr).
static var _ctrl_just_pressed : bool = false
## Cross-check with the live keyboard, so a release lost to another window cannot keep AltGr "held".
## Tests switch it off: they feed events without pressing real keys.
static var check_keyboard : bool = true


static func feed(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null:
		return
	if key.echo:
		_ctrl_just_pressed = false  # a Ctrl held long enough to repeat is a real one
		return
	if key.keycode == KEY_ALT and key.location == KEY_LOCATION_RIGHT:
		_held = key.pressed
		if key.pressed:
			_ctrl_is_fake = _ctrl_just_pressed
		_ctrl_just_pressed = false
		return
	if key.keycode == KEY_CTRL:
		_ctrl_just_pressed = key.pressed and key.location != KEY_LOCATION_RIGHT
		if not key.pressed:
			_ctrl_is_fake = false
		return
	_ctrl_just_pressed = false


static func is_held() -> bool:
	return _held and (not check_keyboard or Input.is_key_pressed(KEY_ALT))


## Whether `action` is currently pressed only because of AltGr's fake Ctrl.
static func masks(action: StringName) -> bool:
	return _ctrl_is_fake and (not check_keyboard or Input.is_key_pressed(KEY_CTRL)) and _bound_to_ctrl(action)


static func strength(action: StringName) -> float:
	return 0.0 if masks(action) else Input.get_action_strength(action)


## Drop-in for Input.get_axis(negative, positive).
static func axis(negative: StringName, positive: StringName) -> float:
	return strength(positive) - strength(negative)


## Forget everything: the window lost the focus, so the releases will not arrive.
static func reset() -> void:
	_held = false
	_ctrl_is_fake = false
	_ctrl_just_pressed = false


## Read from the InputMap rather than assumed, so an action the player rebound to Ctrl is covered.
static func _bound_to_ctrl(action: StringName) -> bool:
	if not InputMap.has_action(action):
		return false
	for event in InputMap.action_get_events(action):
		var key := event as InputEventKey
		if key != null and KEY_CTRL in [key.physical_keycode, key.keycode] and key.location != KEY_LOCATION_RIGHT:
			return true
	return false
