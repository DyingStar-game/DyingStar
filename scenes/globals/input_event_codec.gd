class_name InputEventCodec
extends RefCounted
## The text a remapped binding is saved as in user://inputs.map, and back. One place for both
## directions: the controls page writes it, SettingsManager reads it at boot, and a format known to
## only one of the two loses bindings in silence.
##
## Keys: Godot's own "Alt+T" (as_text_physical_keycode / find_keycode_from_string).
## Mouse buttons: "mouse_<index>", prefixed by their modifiers, "Alt+mouse_4". The prefix is what the
## old format lacked: Alt + wheel was saved as a bare wheel and came back without its Alt. A file
## written before it ("mouse_4") still reads, as a button without modifiers.

const MOUSE_PREFIX := "mouse_"


static func encode(event: InputEvent) -> String:
	if event is InputEventKey:
		return (event as InputEventKey).as_text_physical_keycode()
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		return _modifiers_text(mb) + MOUSE_PREFIX + str(mb.button_index)
	return ""


static func decode(text: String) -> InputEvent:
	var mouse_at: int = text.find(MOUSE_PREFIX)
	if mouse_at >= 0:
		var mouse := InputEventMouseButton.new()
		mouse.button_index = int(text.substr(mouse_at + MOUSE_PREFIX.length())) as MouseButton
		var mods: String = text.substr(0, mouse_at)
		mouse.ctrl_pressed = mods.contains("Ctrl+")
		mouse.alt_pressed = mods.contains("Alt+")
		mouse.shift_pressed = mods.contains("Shift+")
		mouse.meta_pressed = mods.contains("Meta+")
		return mouse
	var key := InputEventKey.new()
	# find_keycode_from_string encodes modifiers in the high bits; split them back out so a saved
	# "Alt + ²" reloads WITH its Alt (else remapped modifier bindings lose the modifier).
	var kc: int = OS.find_keycode_from_string(text)
	key.physical_keycode = (kc & KEY_CODE_MASK) as Key
	key.alt_pressed = (kc & KEY_MASK_ALT) != 0
	key.ctrl_pressed = (kc & KEY_MASK_CTRL) != 0
	key.shift_pressed = (kc & KEY_MASK_SHIFT) != 0
	key.meta_pressed = (kc & KEY_MASK_META) != 0
	return key


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
