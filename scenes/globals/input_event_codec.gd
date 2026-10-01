class_name InputEventCodec
extends RefCounted
## The text a remapped binding is saved as in user://inputs.map, and back. One place for both
## directions: the controls page writes it, SettingsManager reads it at boot, and a format known to
## only one of the two loses bindings in silence.
##
## Keys: the modifiers, then Godot's name for the key, "Alt+T".
## Mouse buttons: "mouse_<index>", prefixed by their modifiers, "Alt+mouse_4". The prefix is what the
## old format lacked: Alt + wheel was saved as a bare wheel and came back without its Alt. A file
## written before it ("mouse_4") still reads, as a button without modifiers.
##
## The modifiers are written by this file, the same four words for keys and buttons and on every
## system. Godot's own text for a key names Meta after the machine ("Windows", "Command"), which is
## nothing to write in a file.

const MOUSE_PREFIX := "mouse_"
## Gamepads: "joy_button_<index>", and "joy_axis_<axis>_+" or "_-" for a stick or a trigger pushed one
## way. No modifiers: a pad has none.
const JOY_BUTTON_PREFIX := "joy_button_"
const JOY_AXIS_PREFIX := "joy_axis_"
## Prefix to flag, in the order they are written.
const MODIFIER_PREFIXES: Dictionary = {
	"Ctrl+": KEY_MASK_CTRL,
	"Alt+": KEY_MASK_ALT,
	"Shift+": KEY_MASK_SHIFT,
	"Meta+": KEY_MASK_META,
}


static func encode(event: InputEvent) -> String:
	if event is InputEventKey:
		var key: InputEventKey = event
		return _modifiers_text(key) + OS.get_keycode_string(key.physical_keycode)
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		return _modifiers_text(mb) + MOUSE_PREFIX + str(mb.button_index)
	if event is InputEventJoypadButton:
		return JOY_BUTTON_PREFIX + str((event as InputEventJoypadButton).button_index)
	if event is InputEventJoypadMotion:
		var motion: InputEventJoypadMotion = event
		return JOY_AXIS_PREFIX + str(motion.axis) + ("_-" if motion.axis_value < 0.0 else "_+")
	return ""


static func decode(text: String) -> InputEvent:
	if text.begins_with(JOY_BUTTON_PREFIX):
		var button := InputEventJoypadButton.new()
		button.button_index = int(text.substr(JOY_BUTTON_PREFIX.length())) as JoyButton
		return button
	if text.begins_with(JOY_AXIS_PREFIX):
		var motion := InputEventJoypadMotion.new()
		var axis_text: String = text.substr(JOY_AXIS_PREFIX.length())
		motion.axis = int(axis_text.get_slice("_", 0)) as JoyAxis
		motion.axis_value = -1.0 if axis_text.ends_with("_-") else 1.0
		return motion
	var mask: int = 0
	var rest: String = text
	var found: bool = true
	while found:
		found = false
		for prefix: String in MODIFIER_PREFIXES:
			if rest.begins_with(prefix):
				mask |= int(MODIFIER_PREFIXES[prefix])
				rest = rest.substr(prefix.length())
				found = true
	var made: InputEventWithModifiers
	if rest.begins_with(MOUSE_PREFIX):
		var mouse := InputEventMouseButton.new()
		mouse.button_index = int(rest.substr(MOUSE_PREFIX.length())) as MouseButton
		made = mouse
	else:
		var key := InputEventKey.new()
		# What is left may still carry modifiers in Godot's own words, in a file written before this
		# one spelt them itself: find_keycode_from_string puts those in the high bits.
		var kc: int = OS.find_keycode_from_string(rest)
		key.physical_keycode = (kc & KEY_CODE_MASK) as Key
		mask |= kc & KEY_MODIFIER_MASK
		made = key
	made.ctrl_pressed = (mask & KEY_MASK_CTRL) != 0
	made.alt_pressed = (mask & KEY_MASK_ALT) != 0
	made.shift_pressed = (mask & KEY_MASK_SHIFT) != 0
	made.meta_pressed = (mask & KEY_MASK_META) != 0
	return made


static func _modifiers_text(event: InputEventWithModifiers) -> String:
	var mods: String = ""
	if event.ctrl_pressed:
		mods += "Ctrl+"
	if event.alt_pressed:
		mods += "Alt+"
	if event.shift_pressed:
		mods += "Shift+"
	if event.meta_pressed:
		mods += "Meta+"
	return mods
