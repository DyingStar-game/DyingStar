class_name InputLabel
extends RefCounted
## How a key is named for the player, in one place.
##
## Lived inside the controls page, which was the only screen that named keys. The HUD prompts wrote
## theirs by hand — "[E] Drop", "[E] Drive Seat" — so a player who rebound "interact" read a prompt
## telling them to press a key that no longer does anything. Prompts now ask here, and there is one
## answer per key for the whole game.


## The key an action is bound to, as printed on the player's keyboard. Empty when the action has no
## binding at all, so a caller can leave the brackets out rather than show "[]".
static func for_action(action: StringName) -> String:
	if not InputMap.has_action(action):
		return ""
	var events : Array[InputEvent] = InputMap.action_get_events(action)
	return for_event(events[0]) if not events.is_empty() else ""


static func for_event(event: InputEvent) -> String:
	if event is InputEventKey:
		# Bound by the letter printed on the key rather than by where the key is (the speaker on N, the
		# microphone on M, wherever a layout puts them): it has no place to look the label up from, and
		# read as a place it came out with no name at all.
		if event.physical_keycode == KEY_NONE:
			return _modifiers(event) + OS.get_keycode_string(event.keycode)
		return _modifiers(event) + _physical_key_name(event.physical_keycode)
	if event is InputEventMouseButton:
		return _modifiers(event) + _mouse_button_name(event.button_index)
	return event.as_text()


## The modifiers held with a key OR a mouse button, so "Alt + ²" and "Alt + wheel" don't read as a
## bare key. They stay untranslated: Ctrl/Alt/Shift are what is written on the keys themselves.
static func _modifiers(event: InputEventWithModifiers) -> String:
	var system: String = OS.get_name()
	var mods := ""
	if event.ctrl_pressed:
		mods += "Ctrl + "
	if event.alt_pressed:
		mods += alt_name(system) + " + "
	if event.shift_pressed:
		mods += "Shift + "
	if event.meta_pressed:
		mods += meta_name(system) + " + "
	return mods


## What the Alt key is called on [param system] (OS.get_name()): a Mac keyboard prints Option.
static func alt_name(system: String) -> String:
	return "Option" if system == "macOS" else "Alt"


## What the Meta key is called on [param system]: no keyboard has "Meta" written on it.
static func meta_name(system: String) -> String:
	match system:
		"macOS":
			return "Cmd"
		"Windows":
			return "Win"
	return "Super"


## A mouse button's name WITHOUT the modifiers Godot's as_text() would prepend in its own format.
static func _mouse_button_name(index: int) -> String:
	var bare := InputEventMouseButton.new()
	bare.button_index = index as MouseButton
	return bare.as_text()


## Human key name for a physical keycode: prefer the label printed on the key in the active layout
## (e.g. "²" on an AZERTY row), and fall back to the layout keycode name (e.g. "Apostrophe") when the
## key has no printable label. Physical keycodes keep bindings layout-independent; this only affects
## how they READ.
static func _physical_key_name(physical_keycode: int) -> String:
	var label := DisplayServer.keyboard_get_label_from_physical(physical_keycode)
	if label != 0:
		var label_text := OS.get_keycode_string(label)
		if label_text.strip_edges() != "":
			return label_text
	var keycode := DisplayServer.keyboard_get_keycode_from_physical(physical_keycode)
	return OS.get_keycode_string(keycode)
