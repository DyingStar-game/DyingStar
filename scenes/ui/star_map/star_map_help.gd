class_name StarMapHelp
extends RefCounted
## The help line at the foot of the star map: how to drive it, named with the keys the player
## actually has. It used to be one fixed sentence ("click: select   double click: go there…"), true of
## the defaults only; every gesture is a rebindable action now (Settings > Controls > Star map), so
## the line is built from the bindings, for the device in the player's hands.

## Each gesture: its label, then one or more slots ("zoom" has two: in and out), each slot listing
## the actions that can fill it, by preference. The first one bound on the device fills the slot —
## the wheel's step on the mouse, the triggers' held zoom on the pad. A gesture with no slot filled
## is left out of the line rather than shown with nothing to press.
const GESTURES : Array[Dictionary] = [
	{"label": "%%HUD_MAP_HELP_SELECT", "slots": [[&"star_map_select"]]},
	{"label": "%%HUD_MAP_HELP_TRAVEL", "slots": [[&"star_map_select"]], "twice": true},
	{"label": "%%HUD_MAP_HELP_RESET", "slots": [[&"star_map_reset"]]},
	{"label": "%%HUD_MAP_HELP_ORBIT", "slots": [[&"star_map_orbit", &"star_map_orbit_left"]]},
	{"label": "%%HUD_MAP_HELP_ZOOM", "slots": [[&"star_map_zoom_step_in", &"star_map_zoom_in"],
			[&"star_map_zoom_step_out", &"star_map_zoom_out"]]},
	{"label": "%%HUD_MAP_HELP_CLOSE", "slots": [[&"star_map"], [&"pause"]]},
]
const GAP : String = "   "
const OR : String = " / "


## The line for the device [param kind] (InputDevice.Kind).
static func text(kind: InputDevice.Kind) -> String:
	var parts : PackedStringArray = []
	for gesture: Dictionary in GESTURES:
		var keys : PackedStringArray = []
		for slot: Array in gesture["slots"]:
			var key : String = _first_bound(slot, kind)
			if key != "":
				keys.append(key)
		if keys.is_empty():
			continue
		var pressed : String = OR.join(keys)
		if gesture.get("twice", false):
			pressed = TranslationServer.translate("%%HUD_MAP_HELP_TWICE") % pressed
		parts.append(TranslationServer.translate("%%HUD_MAP_HELP_ITEM") % [pressed,
				TranslationServer.translate(str(gesture["label"]))])
	return GAP.join(parts)


## The name of the first of [param actions] bound on [param kind], or "".
static func _first_bound(actions: Array, kind: InputDevice.Kind) -> String:
	for action: StringName in actions:
		var events : Array[InputEvent] = InputDevice.bindings(action, kind)
		if not events.is_empty():
			return _name(events[0])
	return ""


## A stick is named as a whole ("RS"), not by the one direction its action listens to ("RS Left"):
## the line says what turns the view, and the whole stick does.
static func _name(event: InputEvent) -> String:
	var motion := event as InputEventJoypadMotion
	if motion != null and motion.axis < JOY_AXIS_TRIGGER_LEFT:
		return InputLabel.pad_stick_name(motion.axis, InputDevice.likely_family())
	return InputLabel.for_event(event)
