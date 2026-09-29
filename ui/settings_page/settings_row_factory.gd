class_name SettingsRowFactory
extends RefCounted
## Builds settings lines from code, looking exactly like the ones written by hand in the pages'
## scenes: Label on the left, control pushed to the right.
##
## An instance rather than static functions because the SAME rows are built at two sizes: the
## Graphics page (Poppins SettingsStyle.FONT_SIZE, 200 px controls, like every other line of it) and the in-game overlay,
## which has to stay small enough to leave the scene it is tuning visible.

const FONT : FontFile = preload("res://ui/Poppins-Regular.ttf")
## size_flags_horizontal = 10 in the scenes: expand, then shrink to the end — the control hugs the
## right edge whatever the label's length.
const _PUSH_RIGHT : int = Control.SIZE_EXPAND | Control.SIZE_SHRINK_END
## A slider's number, as a share of the control width: slider and number together are exactly as
## wide as any other control of the line, so every right-hand column lines up.
const _VALUE_SHARE : float = 0.3
## HBoxContainer's gap between the slider and its number.
const _GAP_PX : float = 4.0

var label_size : int
## 0 keeps the theme's size, which is what the hand-written page controls use.
var control_size : int
var control_width : float
## Captions and headings wrap onto several lines instead of widening their line. For a narrow
## container (the in-game overlay): an unwrapped caption such as "Anticrénelage multi-échantillons
## (MSAA)" made the line wider than the panel, which cut every control off on the right.
var wrap_captions : bool
var _label_settings : LabelSettings
var _header_settings : LabelSettings


func _init(label_font_size: int = SettingsStyle.FONT_SIZE, control_font_size: int = 0, width: float = 200.0,
		wrap: bool = false) -> void:
	label_size = label_font_size
	control_size = control_font_size
	control_width = width
	wrap_captions = wrap
	_label_settings = LabelSettings.new()
	_label_settings.font = FONT
	_label_settings.font_size = label_size
	_header_settings = LabelSettings.new()
	_header_settings.font = FONT
	_header_settings.font_size = label_size + 1


## A heading between groups of lines: the amber "you are here" colour, capitals, a step above the
## lines, and a rule under it across the width that separates it from the group above.
func header(text_key: String) -> Label:
	var label := Label.new()
	label.text = text_key
	label.uppercase = true
	label.modulate = SettingsStyle.ACTIVE_COLOR
	label.label_settings = _header_settings
	var rule := StyleBoxFlat.new()
	rule.bg_color = Color.TRANSPARENT
	rule.border_width_bottom = 1
	rule.border_color = SettingsStyle.HEADER_RULE
	rule.content_margin_top = 12.0
	rule.content_margin_bottom = 4.0
	label.add_theme_stylebox_override("normal", rule)
	_wrap(label)
	return label


## An empty line with its caption; the caller adds the control(s). Its label is reachable as
## row.get_child(0). A tooltip set on the LINE shows anywhere over it: the line and its caption
## both PASS the mouse, so hovering the caption or the gap beside it finds the line's tooltip.
func row(label_key: String) -> HBoxContainer:
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_PASS
	var label := Label.new()
	label.text = label_key
	label.label_settings = _label_settings
	label.size_flags_horizontal = Control.SIZE_FILL
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	_wrap(label)
	line.add_child(label)
	return line


## In wrap mode, a caption takes whatever width the controls leave and breaks between words.
func _wrap(label: Label) -> void:
	if not wrap_captions:
		return
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# The control beside it expands too (to hug the right edge): without a heavier ratio the two
	# would split the spare width evenly and the caption would wrap long before it had to.
	label.size_flags_stretch_ratio = 3.0


func option_button() -> OptionButton:
	var button := OptionButton.new()
	_style_control(button)
	return button


## The settings pages' toggle: a Button showing On / Off, never a CheckBox.
func toggle() -> Button:
	var switch : Button = button("")
	switch.toggle_mode = true
	return switch


## A plain push button showing `text_key` ("Open", "Apply").
func button(text_key: String) -> Button:
	var push := Button.new()
	push.text = text_key
	_style_control(push)
	return push


func slider(min_value: float, max_value: float, step: float) -> HSlider:
	var bar := HSlider.new()
	bar.min_value = min_value
	bar.max_value = max_value
	bar.step = step
	bar.custom_minimum_size = Vector2(control_width * (1.0 - _VALUE_SHARE) - _GAP_PX, 0)
	bar.size_flags_horizontal = _PUSH_RIGHT
	bar.size_flags_vertical = Control.SIZE_FILL
	return bar


## The number shown beside a slider.
func value_label() -> Label:
	var label := Label.new()
	label.custom_minimum_size = Vector2(control_width * _VALUE_SHARE, 0)
	label.label_settings = _label_settings
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return label


func _style_control(control: Control) -> void:
	control.custom_minimum_size = Vector2(control_width, 0)
	control.size_flags_horizontal = _PUSH_RIGHT
	control.add_theme_font_override("font", FONT)
	if control_size > 0:
		control.add_theme_font_size_override("font_size", control_size)
