class_name DevClockWarning
extends Label
## Red banner at the top of the screen while the dev clock (+ / -, Globals.debug_time_offset) is shifted.
##
## That clock is THIS client's alone, on purpose: it is for looking at an atmosphere at another hour, not
## an admin tool, and the server never learns of it. Everything the server works out from the time then
## disagrees with what this client draws — an orbital station stands somewhere else, and leaving it lands
## you where the SERVER has it: measured on the opposite side of the planet, with about 12 h of offset.
## Hence always in view, debug panels shown or not. A photo (F7) hides it with the rest of the interface.

const COLOR := Color(1.0, 0.3, 0.3)
const FONT_SIZE := 20
const MARGIN_TOP := 48.0

## The offset the text was written for; NAN forces the first write (NAN equals nothing, itself included).
var _shown_offset: float = NAN


func _ready() -> void:
	name = "DevClockWarning"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The text is built from tr() with a number in it: there is nothing left for the Label to translate.
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_theme_color_override("font_color", COLOR)
	add_theme_color_override("font_outline_color", Color.BLACK)
	add_theme_constant_override("outline_size", 6)
	add_theme_font_size_override("font_size", FONT_SIZE)
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	offset_top = MARGIN_TOP
	visible = false


func _process(_delta: float) -> void:
	var offset: float = Globals.debug_time_offset
	if offset == _shown_offset:
		return
	_shown_offset = offset
	visible = not is_zero_approx(offset)
	if visible:
		text = tr("%%HUD_DEV_CLOCK_WARNING") % (offset / 3600.0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		_shown_offset = NAN  # rewrite it in the new language
