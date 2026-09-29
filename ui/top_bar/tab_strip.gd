class_name TabStrip
extends HBoxContainer
## A row of flat text entries, one of them active: capitals, the active one amber with a line under
## it — SQUAD's menu bar and its settings tabs. The menu's top bar (TopBar) and the settings tabs are
## both one of these, at two sizes.
##
## An entry's text is its translation key upper-cased once translated (a key cannot be upper-cased),
## so it is redone when the language changes.

signal selected(key: StringName)

const _UNDERLINE_PX : int = 2
const _PAD_X : float = 4.0
const _PAD_BOTTOM : float = 6.0

var font_size : int
var _buttons : Dictionary = {}  # key -> Button
var _labels : Dictionary = {}  # key -> translation key
var _prefixes : Dictionary = {}  # key -> text drawn before it (an arrow)
var _active : StringName = &""


func _init(p_font_size: int = 20, separation: int = 36) -> void:
	font_size = p_font_size
	add_theme_constant_override("separation", separation)
	alignment = BoxContainer.ALIGNMENT_END


## `prefix` is drawn before the translated text, as is: an arrow, say.
func add_entry(key: StringName, label_key: String, prefix: String = "") -> Button:
	var button := Button.new()
	# NOT flat: a flat button draws no stylebox, and the active line under the entry is one.
	button.focus_mode = Control.FOCUS_NONE
	button.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	button.add_theme_font_override("font", SettingsRowFactory.FONT)
	button.add_theme_font_size_override("font_size", font_size)
	button.add_theme_color_override("font_hover_color", SettingsStyle.ACTIVE_COLOR)
	button.add_theme_color_override("font_pressed_color", SettingsStyle.ACTIVE_COLOR)
	button.pressed.connect(func() -> void: selected.emit(key))
	_buttons[key] = button
	_labels[key] = label_key
	_prefixes[key] = prefix
	add_child(button)
	_style(key)
	return button


func button(key: StringName) -> Button:
	return _buttons.get(key)


func active() -> StringName:
	return _active


func set_active(key: StringName) -> void:
	_active = key
	for k: StringName in _buttons:
		_style(k)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		for k: StringName in _buttons:
			_style(k)


func _style(key: StringName) -> void:
	var button : Button = _buttons[key]
	var on : bool = key == _active
	button.text = _prefixes[key] + tr(_labels[key]).to_upper()
	button.add_theme_color_override("font_color", SettingsStyle.ACTIVE_COLOR if on else SettingsStyle.INACTIVE_COLOR)
	var style := StyleBoxFlat.new()
	style.bg_color = Color.TRANSPARENT
	style.content_margin_left = _PAD_X
	style.content_margin_right = _PAD_X
	style.content_margin_bottom = _PAD_BOTTOM
	if on:
		style.border_width_bottom = _UNDERLINE_PX
		style.border_color = SettingsStyle.ACTIVE_COLOR
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		button.add_theme_stylebox_override(state, style)
