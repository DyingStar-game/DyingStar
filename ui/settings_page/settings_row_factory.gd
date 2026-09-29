class_name SettingsRowFactory
extends RefCounted
## Builds settings lines from code, looking exactly like the ones written by hand in the pages'
## scenes: Label on the left, control pushed to the right.
##
## An instance rather than static functions because the SAME rows are built at two sizes: the
## Graphics page (Poppins 28, 200 px controls, like every other line of it) and the in-game overlay,
## which has to stay small enough to leave the scene it is tuning visible.

const FONT : FontFile = preload("res://ui/Poppins-Regular.ttf")
## size_flags_horizontal = 10 in the scenes: expand, then shrink to the end — the control hugs the
## right edge whatever the label's length.
const _PUSH_RIGHT : int = Control.SIZE_EXPAND | Control.SIZE_SHRINK_END

var label_size : int
## 0 keeps the theme's size, which is what the hand-written page controls use.
var control_size : int
var control_width : float
var _label_settings : LabelSettings


func _init(label_font_size: int = 28, control_font_size: int = 0, width: float = 200.0) -> void:
	label_size = label_font_size
	control_size = control_font_size
	control_width = width
	_label_settings = LabelSettings.new()
	_label_settings.font = FONT
	_label_settings.font_size = label_size


## A heading between groups of lines: the amber "you are here" colour, capitals — the controls
## page's family headings, so both pages speak the same visual language.
func header(text_key: String) -> Label:
	var label := Label.new()
	label.text = text_key
	label.uppercase = true
	label.modulate = SettingsStyle.ACTIVE_COLOR
	label.label_settings = _label_settings
	return label


## An empty line with its caption; the caller adds the control(s). Its label is reachable as
## row.get_child(0). PASS on the label so a greyed option can still explain itself in a tooltip.
func row(label_key: String) -> HBoxContainer:
	var line := HBoxContainer.new()
	var label := Label.new()
	label.text = label_key
	label.label_settings = _label_settings
	label.size_flags_horizontal = Control.SIZE_FILL
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	line.add_child(label)
	return line


func option_button() -> OptionButton:
	var button := OptionButton.new()
	_style_control(button)
	return button


## The settings pages' toggle: a Button showing On / Off, never a CheckBox.
func toggle() -> Button:
	var button := Button.new()
	button.toggle_mode = true
	_style_control(button)
	return button


func slider(min_value: float, max_value: float, step: float) -> HSlider:
	var bar := HSlider.new()
	bar.min_value = min_value
	bar.max_value = max_value
	bar.step = step
	bar.custom_minimum_size = Vector2(control_width * 0.8, 0)
	bar.size_flags_horizontal = _PUSH_RIGHT
	bar.size_flags_vertical = Control.SIZE_FILL
	return bar


## The number shown beside a slider.
func value_label() -> Label:
	var label := Label.new()
	label.custom_minimum_size = Vector2(control_width * 0.45, 0)
	label.label_settings = _label_settings
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return label


func _style_control(control: Control) -> void:
	control.custom_minimum_size = Vector2(control_width, 0)
	control.size_flags_horizontal = _PUSH_RIGHT
	control.add_theme_font_override("font", FONT)
	if control_size > 0:
		control.add_theme_font_size_override("font_size", control_size)
