class_name InputLabel
extends RefCounted
## How a key is named for the player, in one place.
##
## Lived inside the controls page, which was the only screen that named keys. The HUD prompts wrote
## theirs by hand — "[E] Drop", "[E] Drive Seat" — so a player who rebound "interact" read a prompt
## telling them to press a key that no longer does anything. Prompts now ask here, and there is one
## answer per key for the whole game.


## What a gamepad's buttons are called, by JoyButton index, per InputDevice.Family. A word is a
## translation key; the rest is what is printed on the pad. Past the end of a list: numbered.
const PAD_BUTTONS : Dictionary = {
	InputDevice.Family.XBOX: ["A", "B", "X", "Y", "View", "Xbox", "Menu", "LS", "RS", "LB", "RB"],
	InputDevice.Family.PLAYSTATION: ["%%PAD_PS_CROSS", "%%PAD_PS_CIRCLE", "%%PAD_PS_SQUARE",
			"%%PAD_PS_TRIANGLE", "Create", "PS", "Options", "L3", "R3", "L1", "R1"],
	InputDevice.Family.NINTENDO: ["B", "A", "Y", "X", "-", "Home", "+", "LS", "RS", "L", "R"],
}
## The cross, JoyButton 11 to 14, the same on every pad.
const PAD_DPAD : Array[String] = ["%%PAD_DPAD_UP", "%%PAD_DPAD_DOWN", "%%PAD_DPAD_LEFT", "%%PAD_DPAD_RIGHT"]
## The mouse buttons a player binds, by MouseButton index: named in the game's language. Godot's own
## names ("Left Mouse Button") are English whatever the language; past this list they are kept.
const MOUSE_BUTTONS : Dictionary = {
	MOUSE_BUTTON_LEFT: "%%MOUSE_LEFT", MOUSE_BUTTON_RIGHT: "%%MOUSE_RIGHT", MOUSE_BUTTON_MIDDLE: "%%MOUSE_MIDDLE",
	MOUSE_BUTTON_WHEEL_UP: "%%MOUSE_WHEEL_UP", MOUSE_BUTTON_WHEEL_DOWN: "%%MOUSE_WHEEL_DOWN",
}
## The mouse buttons a prompt shows as a picture of the mouse rather than as a word, by MouseButton
## index: read at a glance and in any language. A button pressed with a modifier keeps its words.
const MOUSE_ICONS : Dictionary = {
	MOUSE_BUTTON_LEFT: "res://assets/textures/input/mouse/mouse_left.png",
	MOUSE_BUTTON_RIGHT: "res://assets/textures/input/mouse/mouse_right.png",
	MOUSE_BUTTON_MIDDLE: "res://assets/textures/input/mouse/mouse_middle.png",
	MOUSE_BUTTON_WHEEL_UP: "res://assets/textures/input/mouse/mouse_wheel_up.png",
	MOUSE_BUTTON_WHEEL_DOWN: "res://assets/textures/input/mouse/mouse_wheel_down.png",
	MOUSE_BUTTON_XBUTTON1: "res://assets/textures/input/mouse/mouse_back.png",
	MOUSE_BUTTON_XBUTTON2: "res://assets/textures/input/mouse/mouse_forward.png",
}
## The two sticks and the two triggers, per family: [left stick, right stick, left trigger, right].
const PAD_AXES : Dictionary = {
	InputDevice.Family.XBOX: ["LS", "RS", "LT", "RT"],
	InputDevice.Family.PLAYSTATION: ["L", "R", "L2", "R2"],
	InputDevice.Family.NINTENDO: ["LS", "RS", "ZL", "ZR"],
}


## The key an action is bound to, as printed on what the player has in their hands: the gamepad's
## button when they are playing on the gamepad, the keyboard's key otherwise — and the other device's
## when theirs has no binding for it. Empty when the action has no binding at all, so a caller can
## leave the brackets out rather than show "[]".
static func for_action(action: StringName) -> String:
	var event := _first_event(action)
	return for_event(event) if event != null else ""


## The key an action is bound to, for a RichTextLabel ([member RichTextLabel.bbcode_enabled]): the
## picture of the mouse button, [param icon_px] high, when it is a bare mouse button; else its name
## in brackets ("[E]"), the brackets escaped. Empty when the action has no binding, like
## [method for_action].
static func rich_for_action(action: StringName, icon_px: int) -> String:
	var event := _first_event(action)
	if event == null:
		return ""
	var icon := icon_for_event(event)
	if icon != null:
		return "[img height=%d]%s[/img]" % [icon_px, icon.resource_path]
	return "[lb]%s]" % escape(for_event(event))


## [param text] shown as it is by a RichTextLabel: its opening brackets escaped, so no word of a
## translation or of a key name ("[B]") is read as a tag.
static func escape(text: String) -> String:
	return text.replace("[", "[lb]")


## The picture of [param event]'s mouse button (MOUSE_ICONS), or null: not a mouse button, a button
## with no picture, or one pressed with a modifier ("Alt + wheel" keeps its words).
static func icon_for_event(event: InputEvent) -> Texture2D:
	var button := event as InputEventMouseButton
	if button == null or _modifiers(button) != "" or not MOUSE_ICONS.has(button.button_index):
		return null
	return load(str(MOUSE_ICONS[button.button_index])) as Texture2D


## The first binding of [param action] on the device in hand, else on the other one; null when it has
## none. What [method for_action] and [method rich_for_action] both name.
static func _first_event(action: StringName) -> InputEvent:
	if not InputMap.has_action(action):
		return null
	var events : Array[InputEvent] = InputDevice.bindings(action, InputDevice.last)
	if events.is_empty():
		events = InputMap.action_get_events(action)
	return events[0] if not events.is_empty() else null


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
	if event is InputEventJoypadButton:
		return pad_button_name((event as InputEventJoypadButton).button_index, InputDevice.likely_family())
	if event is InputEventJoypadMotion:
		var motion : InputEventJoypadMotion = event
		return pad_axis_name(motion.axis, motion.axis_value, InputDevice.likely_family())
	return event.as_text()


## A gamepad button by its JoyButton [param index], as printed on a pad of [param family].
static func pad_button_name(index: int, family: InputDevice.Family) -> String:
	if index >= JOY_BUTTON_DPAD_UP and index <= JOY_BUTTON_DPAD_RIGHT and family != InputDevice.Family.GENERIC:
		return _tr("%%PAD_DPAD") + " " + _tr(PAD_DPAD[index - JOY_BUTTON_DPAD_UP])
	var names : Array = PAD_BUTTONS.get(family, [])
	if index >= 0 and index < names.size():
		return _tr(str(names[index]))
	return _tr("%%PAD_BUTTON") % (index + 1)


## A stick or a trigger, [param axis] pushed towards the sign of [param value], on a pad of
## [param family]: "LS Left", "RT". Numbered on a device Godot does not know (a flight stick).
static func pad_axis_name(axis: int, value: float, family: InputDevice.Family) -> String:
	var names : Array = PAD_AXES.get(family, [])
	if names.is_empty() or axis > JOY_AXIS_TRIGGER_RIGHT:
		return _tr("%%PAD_AXIS") % [axis + 1, "-" if value < 0.0 else "+"]
	if axis >= JOY_AXIS_TRIGGER_LEFT:
		return str(names[2 + axis - JOY_AXIS_TRIGGER_LEFT])
	var stick : String = pad_stick_name(axis, family)
	var horizontal : bool = axis == JOY_AXIS_LEFT_X or axis == JOY_AXIS_RIGHT_X
	var way : String = "%%PAD_DPAD_UP" if value < 0.0 else "%%PAD_DPAD_DOWN"
	if horizontal:
		way = "%%PAD_DPAD_LEFT" if value < 0.0 else "%%PAD_DPAD_RIGHT"
	return stick + " " + _tr(way)


## The stick [param axis] belongs to, as a whole ("RS"), on a pad of [param family]: for a line that
## says what a stick does rather than which way it is pushed. Numbered like pad_axis_name on a device
## Godot does not know.
static func pad_stick_name(axis: int, family: InputDevice.Family) -> String:
	var names : Array = PAD_AXES.get(family, [])
	if names.is_empty() or axis > JOY_AXIS_RIGHT_Y:
		return _tr("%%PAD_AXIS") % [axis + 1, ""]
	return str(names[0 if axis <= JOY_AXIS_LEFT_Y else 1])


## Static, so no tr() of its own: the translation server's.
static func _tr(key: String) -> String:
	return TranslationServer.translate(key) if key.begins_with("%%") else key


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
	if MOUSE_BUTTONS.has(index):
		return _tr(str(MOUSE_BUTTONS[index]))
	var bare := InputEventMouseButton.new()
	bare.button_index = index as MouseButton
	return bare.as_text()


## Human key name for a physical keycode: prefer the label printed on the key in the active layout
## (e.g. "²" on an AZERTY row), and fall back to the layout keycode name (e.g. "Apostrophe") when the
## key has no printable label. Physical keycodes keep bindings layout-independent; this only affects
## how they READ.
static func _physical_key_name(physical_keycode: int) -> String:
	# No keyboard layout to ask without a window (the headless test runner, the server): the key's own
	# name, which is the US one. Asked anyway, the display server answers with an error per key.
	if DisplayServer.get_name() == "headless":
		return OS.get_keycode_string(physical_keycode)
	var label := DisplayServer.keyboard_get_label_from_physical(physical_keycode)
	if label != 0:
		var label_text := OS.get_keycode_string(label)
		if label_text.strip_edges() != "":
			return label_text
	var keycode := DisplayServer.keyboard_get_keycode_from_physical(physical_keycode)
	return OS.get_keycode_string(keycode)
