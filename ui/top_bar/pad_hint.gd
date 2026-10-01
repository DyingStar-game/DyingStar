class_name PadHint
extends Label
## The gamepad button that does something here, written beside it — "LB", "RB" either side of a row
## of tabs — and only while the player is on the gamepad: with the mouse in hand the tabs are clicked,
## and the button names would only be clutter.
##
## Follows InputDevice.last from frame to frame, so taking up the pad brings the hints in and moving
## the mouse sends them away. Names what the action is bound to, so a rebound button is named right.

var action : StringName
## Shown only while this control has the focus — the "A" beside the entry it would press — or null.
var focus_of : Control = null


func _init(p_action: StringName, font_size: int = SettingsStyle.FONT_SIZE) -> void:
	action = p_action
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add_theme_font_override("font", SettingsRowFactory.FONT)
	add_theme_font_size_override("font_size", font_size)
	add_theme_color_override("font_color", SettingsStyle.ACTIVE_COLOR)


func _ready() -> void:
	_refresh()


func _process(_delta: float) -> void:
	_refresh()


func _refresh() -> void:
	var on_pad : bool = InputDevice.last == InputDevice.Kind.GAMEPAD
	var bound : Array[InputEvent] = InputDevice.bindings(action, InputDevice.Kind.GAMEPAD)
	var here : bool = focus_of == null or focus_of.has_focus()
	# Kept in the layout, only see-through, so the tabs do not shift when the hints come and go.
	self_modulate.a = 1.0 if on_pad and here and not bound.is_empty() else 0.0
	var name_now : String = InputLabel.for_event(bound[0]) if not bound.is_empty() else ""
	if text != name_now:
		text = name_now
