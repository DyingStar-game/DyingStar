class_name PadInvite
extends Label
## "Gamepad detected — press A to use it", at the foot of the home screen while a gamepad is plugged in
## and the player has not taken it up yet. Pressing a button on it is taking it: the bar's first entry
## takes the focus (TopBar) and the invitation goes, until the mouse is picked up again.
##
## Names the button as printed on the pad that is there (InputDevice.family_of its name).

const FONT_SIZE : int = 18
## Up from the bottom of the screen.
const MARGIN_PX : float = 40.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	# A band across the bottom of the screen, its text centred: anchored to the bottom edge with a
	# height of its own. Anchored with no height, it started AT the bottom edge and drew below it.
	anchor_left = 0.0
	anchor_right = 1.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_top = -MARGIN_PX - FONT_SIZE * 2.0
	offset_bottom = -MARGIN_PX
	add_theme_font_override("font", SettingsRowFactory.FONT)
	add_theme_font_size_override("font_size", FONT_SIZE)
	add_theme_color_override("font_color", SettingsStyle.ACTIVE_COLOR)
	add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	add_theme_constant_override("outline_size", 4)


func _process(_delta: float) -> void:
	var pads : Array[int] = Input.get_connected_joypads()
	visible = not pads.is_empty() and InputDevice.last != InputDevice.Kind.GAMEPAD
	if visible:
		text = invitation(InputDevice.family_of(Input.get_joy_name(pads[0]), Input.is_joy_known(pads[0])))


## The invitation for a pad of [param family]: its bottom button named as printed on it.
static func invitation(family: InputDevice.Family) -> String:
	return TranslationServer.translate("%%MENU_PAD_DETECTED") % InputLabel.pad_button_name(JOY_BUTTON_A, family)
