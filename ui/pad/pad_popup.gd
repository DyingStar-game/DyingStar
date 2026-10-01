class_name PadPopup
extends CanvasLayer
## "Gamepad detected": a small window over the home screen when it opens with a gamepad plugged in (or
## when one is plugged in while it is up), saying the menus and the game can be played with it. Once a
## launch: back from a game to the menu, it does not come up again.
##
## In the menu's own look — the top bar's dark strip, the heading in the active amber —
## over a veil across the whole screen that says the rest waits. OK is named with the pad's own
## button, "OK (A)", and A, Enter, B or Escape close it.
##
## Modal while it is up (MenuFocus.modal): the bar and the tabs leave the focus to it, so the A that
## closes it does not also press the bar's first entry.

signal closed

## Over the top bar (TopBar.LAYER).
const LAYER : int = 7
const WIDTH_PX : float = 420.0
## The top bar's own strip (TopBar._init), a shade more opaque: a window, not a band. No border: a
## white line round it read as foreign to the menu.
const PANEL_COLOR : Color = Color(0.07, 0.08, 0.1, 0.96)
const VEIL_COLOR : Color = Color(0.0, 0.0, 0.0, 0.6)
const BODY_COLOR : Color = Color(0.85, 0.87, 0.92)

## Shown once this launch already.
static var _shown : bool = false

var _ok : Button


## Should the window come up now: a pad is plugged in, and it has not come up yet this launch.
static func wanted() -> bool:
	return not _shown and not Input.get_connected_joypads().is_empty()


func _init() -> void:
	layer = LAYER
	var veil := ColorRect.new()
	veil.color = VEIL_COLOR
	veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(veil)
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(WIDTH_PX, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_COLOR
	style.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", style)
	centre.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	panel.add_child(column)
	var title : Label = _text("%%PAD_POPUP_TITLE", SettingsStyle.FONT_SIZE + 7, SettingsStyle.ACTIVE_COLOR)
	title.uppercase = true
	column.add_child(title)
	var body : Label = _text("%%PAD_POPUP_TEXT", SettingsStyle.FONT_SIZE + 1, BODY_COLOR)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(body)
	# OK in the top bar's style (a strip of one entry), so it reads as the menu's own.
	var strip := TabStrip.new(SettingsStyle.FONT_SIZE + 5)
	strip.alignment = BoxContainer.ALIGNMENT_CENTER
	strip.accept_hints = false  # "OK (A)" names its button already
	strip.allow_focus()
	_ok = strip.add_entry(&"ok", "%%PAD_POPUP_OK")
	strip.selected.connect(func(_key: StringName) -> void: close())
	column.add_child(strip)


func _text(key: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = key
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", SettingsRowFactory.FONT)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _ready() -> void:
	_shown = true
	MenuFocus.modal = true
	# "OK (A)": the pad's own bottom button, as printed on it.
	_ok.text = ok_text(InputDevice.likely_family())
	# On OK at once: A or Enter closes it.
	_ok.grab_focus()


## "OK (A)", the button named as printed on a pad of [param family].
static func ok_text(family: InputDevice.Family) -> String:
	return TranslationServer.translate("%%PAD_POPUP_OK").to_upper() \
			+ " (" + InputLabel.pad_button_name(JOY_BUTTON_A, family) + ")"


## B or Escape closes it too, as OK would.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func close() -> void:
	MenuFocus.modal = false
	closed.emit()
	queue_free()
