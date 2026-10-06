class_name ControlsHelpRows
extends RefCounted
## What the controls help (F1) lists: the main actions, in sections, each with the keys or buttons
## bound to it NOW on one device and the spot of the picture they light up. Read from the InputMap at
## every opening, so a key the player rebound shows as rebound; the labels are the controls page's own
## translation keys.

## [section title, [ {label, actions} ]]. An entry stands for several actions when they are one thing
## to a player (the four move keys). `mouse_motion`: on the mouse, this is the mouse moving.
const SECTIONS : Array = [
	["%%KM_GROUP_ON_FOOT", [
		{"label": "%%HELP_MOVE", "actions": [&"move_forward", &"move_left", &"move_back", &"move_right"]},
		{"label": "%%HELP_LOOK", "actions": [&"look_up", &"look_left", &"look_down", &"look_right"],
				"mouse_motion": true},
		{"label": "%%ACT_JUMP", "actions": [&"jump"]},
		{"label": "%%ACT_SPRINT", "actions": [&"sprint"]},
		{"label": "%%ACT_CROUCH", "actions": [&"crouch"]},
		{"label": "%%ACT_PRONE", "actions": [&"prone"]},
		{"label": "%%ACT_ACTION", "actions": [&"action"]},
		{"label": "%%ACT_TOGGLE_FLASHLIGHT", "actions": [&"toggle_flashlight"]},
		{"label": "%%ACT_EMOTE_WHEEL", "actions": [&"emote_wheel"]},
		{"label": "%%ACT_TOGGLE_TOOL", "actions": [&"toggle_tool"]},
		{"label": "%%ACT_AIM", "actions": [&"aim"]},
		{"label": "%%ACT_PERFORATE", "actions": [&"perforate"]},
	]],
	["%%KM_GROUP_VEHICLE", [
		{"label": "%%ACT_VEHICLE_ACCELERATE", "actions": [&"vehicle_accelerate"]},
		{"label": "%%ACT_VEHICLE_DECELERATE", "actions": [&"vehicle_decelerate"]},
		{"label": "%%ACT_VEHICLE_IGNITION", "actions": [&"vehicle_ignition"]},
		{"label": "%%ACT_BRAKE", "actions": [&"brake"]},
		{"label": "%%ACT_VEHICLE_LIGHTS", "actions": [&"vehicle_lights"]},
		{"label": "%%ACT_VEHICLE_HORN", "actions": [&"vehicle_horn"]},
		{"label": "%%ACT_VEHICLE_SPEED_LIMITER", "actions": [&"vehicle_speed_limiter"]},
		{"label": "%%HELP_LIMITER_SET", "actions": [&"vehicle_limiter_up", &"vehicle_limiter_down"]},
		{"label": "%%ACT_EXIT", "actions": [&"exit"]},
	]],
	["%%KM_GROUP_GENERAL", [
		{"label": "%%ACT_PAUSE", "actions": [&"pause"]},
		{"label": "%%ACT_STAR_MAP", "actions": [&"star_map"]},
		{"label": "%%ACT_SCREENSHOT", "actions": [&"screenshot"]},
		{"label": "%%ACT_GAME_RECORD", "actions": [&"game_record"]},
	]],
]

## Where a pad's buttons and axes sit on the gamepad picture, by JoyButton index / "axis:<JoyAxis>".
const PAD_SPOTS : Dictionary = {
	JOY_BUTTON_A: "a", JOY_BUTTON_B: "b", JOY_BUTTON_X: "x", JOY_BUTTON_Y: "y",
	JOY_BUTTON_BACK: "back", JOY_BUTTON_GUIDE: "guide", JOY_BUTTON_START: "start",
	JOY_BUTTON_LEFT_STICK: "ls", JOY_BUTTON_RIGHT_STICK: "rs",
	JOY_BUTTON_LEFT_SHOULDER: "lb", JOY_BUTTON_RIGHT_SHOULDER: "rb",
	JOY_BUTTON_DPAD_UP: "dpad_up", JOY_BUTTON_DPAD_DOWN: "dpad_down",
	JOY_BUTTON_DPAD_LEFT: "dpad_left", JOY_BUTTON_DPAD_RIGHT: "dpad_right",
}
const PAD_AXIS_SPOTS : Dictionary = {
	JOY_AXIS_LEFT_X: "ls", JOY_AXIS_LEFT_Y: "ls", JOY_AXIS_RIGHT_X: "rs", JOY_AXIS_RIGHT_Y: "rs",
	JOY_AXIS_TRIGGER_LEFT: "lt", JOY_AXIS_TRIGGER_RIGHT: "rt",
}
## The mouse picture's spots, by MouseButton (the wheel turned up or down, or clicked, is the wheel).
const MOUSE_SPOTS : Dictionary = {
	MOUSE_BUTTON_LEFT: "left", MOUSE_BUTTON_RIGHT: "right", MOUSE_BUTTON_MIDDLE: "wheel",
	MOUSE_BUTTON_WHEEL_UP: "wheel", MOUSE_BUTTON_WHEEL_DOWN: "wheel",
}
## The mouse moving (looking around with the mouse is not an InputMap binding).
const MOUSE_MOTION_SPOT : String = "body"


## The help's lines for [param kind], numbered in order: {section, label, number, names, spots}.
## `names`: what is pressed, as the controls page writes it, once each; `spots`: where it lights up. A
## line with nothing bound on that device is left out (and takes no number).
static func rows(kind: InputDevice.Kind) -> Array[Dictionary]:
	var out : Array[Dictionary] = []
	for section: Array in SECTIONS:
		for entry: Dictionary in section[1]:
			var names := PackedStringArray()
			var spots := PackedStringArray()
			for action: StringName in entry["actions"]:
				# Every binding on the device, not the first only: the limiter is T and the wheel's click.
				for event: InputEvent in InputDevice.bindings(action, kind):
					_add_unique(names, name_of(event))
					_add_unique(spots, spot_of(event))
			if kind == InputDevice.Kind.KEYBOARD_MOUSE and entry.get("mouse_motion", false):
				_add_unique(names, InputLabel._tr("%%HELP_MOUSE"))
				_add_unique(spots, MOUSE_MOTION_SPOT)
			if names.is_empty():
				continue
			out.append({"section": section[0], "label": entry["label"], "number": out.size() + 1,
					"names": names, "spots": spots})
	return out


## What the player presses, as the controls page writes it — a stick by its name alone, whichever way
## it is pushed.
static func name_of(event: InputEvent) -> String:
	var motion := event as InputEventJoypadMotion
	if motion != null and motion.axis <= JOY_AXIS_RIGHT_Y:
		return InputLabel.pad_stick_name(motion.axis, InputDevice.likely_family())
	return InputLabel.for_event(event)


## Where [param event] lights up: "key:<physical keycode>" on the drawn keyboard, a spot of the mouse
## or gamepad picture, or "" when there is no such spot.
static func spot_of(event: InputEvent) -> String:
	var key := event as InputEventKey
	if key != null:
		if key.physical_keycode != KEY_NONE:
			return "key:%d" % key.physical_keycode
		return "key:%d" % KeyboardDiagram.physical_of(key.keycode)  # bound by letter: where it is printed
	var button := event as InputEventMouseButton
	if button != null:
		return MOUSE_SPOTS.get(button.button_index, "")
	var pad := event as InputEventJoypadButton
	if pad != null:
		return PAD_SPOTS.get(pad.button_index, "")
	var motion := event as InputEventJoypadMotion
	if motion != null:
		return PAD_AXIS_SPOTS.get(motion.axis, "")
	return ""


## The controls page's families left out of the tooltips: the developers' tools.
const TIP_SKIPPED_GROUPS : Array[String] = ["%%KM_GROUP_DEBUG"]


## Everything each spot does on [param kind], every family of the controls page (the developers' tools
## aside), for the tooltip of a key: {spot: text}, the families as uppercase headings, an action bound
## with a modifier followed by what is held with it ("Alt+H").
static func tips_by_spot(kind: InputDevice.Kind) -> Dictionary:
	var by_spot : Dictionary = {}  # spot -> {family: PackedStringArray}
	for family: String in MenuConfig.ACTION_GROUPS:
		if family in TIP_SKIPPED_GROUPS:
			continue
		var labels : Dictionary = MenuConfig.labels_of(MenuConfig.ACTION_GROUPS[family])
		for action: String in labels:
			for event: InputEvent in InputDevice.bindings(StringName(action), kind):
				var line : String = InputLabel._tr(labels[action])
				if event is InputEventWithModifiers and _has_modifier(event):
					line += "  (%s)" % InputLabel.for_event(event)
				_add_tip(by_spot, spot_of(event), family, line)
	if kind == InputDevice.Kind.KEYBOARD_MOUSE:
		_add_tip(by_spot, MOUSE_MOTION_SPOT, "%%KM_GROUP_ON_FOOT", InputLabel._tr("%%HELP_LOOK"))
	var out : Dictionary = {}
	for spot: String in by_spot:
		var parts := PackedStringArray()
		for family: String in by_spot[spot]:
			parts.append(InputLabel._tr(family).to_upper() + "\n" + "\n".join(by_spot[spot][family]))
		out[spot] = "\n\n".join(parts)
	return out


static func _add_tip(by_spot: Dictionary, spot: String, family: String, line: String) -> void:
	if spot.is_empty():
		return
	var families : Dictionary = by_spot.get(spot, {})
	var lines : PackedStringArray = families.get(family, PackedStringArray())
	if not line in lines:
		lines.append(line)
	families[family] = lines
	by_spot[spot] = families


static func _has_modifier(event: InputEventWithModifiers) -> bool:
	return event.alt_pressed or event.ctrl_pressed or event.shift_pressed or event.meta_pressed


## The numbers of [param rows] at each spot: {spot: PackedInt32Array}.
static func numbers_by_spot(rows_of_kind: Array[Dictionary]) -> Dictionary:
	var out : Dictionary = {}
	for row: Dictionary in rows_of_kind:
		for spot: String in row["spots"]:
			if spot.is_empty():
				continue
			var numbers : PackedInt32Array = out.get(spot, PackedInt32Array())
			numbers.append(row["number"])
			out[spot] = numbers
	return out


static func _add_unique(list: PackedStringArray, value: String) -> void:
	if not value.is_empty() and not value in list:
		list.append(value)
