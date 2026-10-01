class_name PadPopup
extends CanvasLayer
## "Gamepad detected": a small window over the home screen when it opens with a gamepad plugged in (or
## when one is plugged in while it is up), saying the menus and the game can be played with it. OK —
## A on the pad — closes it, and "Don't show again" keeps it closed for good.
##
## Modal while it is up (MenuFocus.modal): the bar and the tabs leave the focus to it, so the A that
## closes it does not also press the bar's first entry.

signal closed

## Over the top bar (TopBar.LAYER).
const LAYER : int = 7
const ICON : Texture2D = preload("res://ui/pad/gamepad.svg")
const WIDTH_PX : float = 360.0
const ICON_HEIGHT_PX : float = 72.0
const PANEL_COLOR : Color = Color(0.13, 0.15, 0.2, 0.98)
const DIM_COLOR : Color = Color(0.0, 0.0, 0.0, 0.45)
const SETTING : String = "pad_popup_hidden"

var _never : CheckBox
var _ok : Button


## Should the window come up now: a pad is plugged in, and the player never asked for it to stop.
static func wanted() -> bool:
	return not Input.get_connected_joypads().is_empty() and not is_turned_off()


## "Don't show again", kept with the other settings (user://settings.ini, general/pad_popup_hidden).
static func is_turned_off() -> bool:
	return SettingsManager.config.get_value("general", SETTING, false)


static func turn_off() -> void:
	SettingsManager.config.set_value("general", SETTING, true)
	SettingsManager.save_settings()


func _init() -> void:
	layer = LAYER
	var dim := ColorRect.new()
	dim.color = DIM_COLOR
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(WIDTH_PX, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_COLOR
	style.set_corner_radius_all(8)
	style.set_content_margin_all(24)
	panel.add_theme_stylebox_override("panel", style)
	centre.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	panel.add_child(column)
	var icon := TextureRect.new()
	icon.texture = ICON
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(0, ICON_HEIGHT_PX)
	column.add_child(icon)
	column.add_child(_text("%%PAD_POPUP_TITLE", 22, SettingsStyle.INACTIVE_COLOR))
	var body : Label = _text("%%PAD_POPUP_TEXT", 16, Color(0.78, 0.8, 0.86))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(body)
	_never = CheckBox.new()
	_never.text = "%%PAD_POPUP_NEVER"
	_never.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_never.add_theme_font_override("font", SettingsRowFactory.FONT)
	column.add_child(_never)
	_ok = Button.new()
	_ok.text = "OK"
	_ok.custom_minimum_size = Vector2(0, 40)
	_ok.add_theme_font_override("font", SettingsRowFactory.FONT)
	_ok.add_theme_font_size_override("font_size", 18)
	_ok.pressed.connect(close)
	column.add_child(_ok)


func _text(key: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = key
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", SettingsRowFactory.FONT)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _ready() -> void:
	MenuFocus.modal = true
	# On OK at once: A or Enter closes it, the cross reaches the box above.
	_ok.grab_focus()


## B or Escape closes it too, as OK would.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func close() -> void:
	if _never.button_pressed:
		turn_off()
	MenuFocus.modal = false
	closed.emit()
	queue_free()
