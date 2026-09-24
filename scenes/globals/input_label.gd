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
		# Show the modifiers too, so an "Alt + ²" binding doesn't read as a bare key. These stay
		# untranslated: Ctrl/Alt/Shift are what is written on the keys themselves.
		var mods := ""
		if event.ctrl_pressed:
			mods += "Ctrl + "
		if event.alt_pressed:
			mods += "Alt + "
		if event.shift_pressed:
			mods += "Shift + "
		if event.meta_pressed:
			mods += "Meta + "
		return mods + _physical_key_name(event.physical_keycode)
	return event.as_text()


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
