class_name TabStrip
extends HBoxContainer
## A row of flat text entries, one of them active: capitals, the active one amber with a line under
## it — SQUAD's menu bar and its settings tabs. The menu's top bar (TopBar) and the settings tabs are
## both one of these, at two sizes.
##
## An entry's text is its translation key upper-cased once translated (a key cannot be upper-cased),
## so it is redone when the language changes.

signal selected(key: StringName)
## The gamepad moved the focus onto an entry (see [method pad_navigation]).
signal focus_stepped

const _UNDERLINE_PX : int = 2
const _PAD_X : float = 4.0
const _PAD_BOTTOM : float = 6.0

var font_size : int
var _buttons : Dictionary = {}  # key -> Button
var _labels : Dictionary = {}  # key -> translation key
var _prefixes : Dictionary = {}  # key -> text drawn before it (an arrow)
var _active : StringName = &""
## The gamepad actions that step to the previous and the next entry, or empty: see [method pad_navigation].
var _pad_previous : StringName = &""
var _pad_next : StringName = &""
## The entries take the focus, for the gamepad's and the arrows' navigation: see [method allow_focus].
var _focusable : bool = false
## Stepping with the pad moves the FOCUS along the entries rather than selecting them: on a bar whose
## entries do things (Quit), a press of a trigger must not do them.
var _step_focus : bool = false


func _init(p_font_size: int = 20, separation: int = 36) -> void:
	font_size = p_font_size
	add_theme_constant_override("separation", separation)
	alignment = BoxContainer.ALIGNMENT_END


## `prefix` is drawn before the translated text, as is: an arrow, say.
func add_entry(key: StringName, label_key: String, prefix: String = "") -> Button:
	var button := Button.new()
	# NOT flat: a flat button draws no stylebox, and the active line under the entry is one.
	button.focus_mode = Control.FOCUS_ALL if _focusable else Control.FOCUS_NONE
	button.add_theme_color_override("font_focus_color", SettingsStyle.ACTIVE_COLOR)
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


## Let the gamepad step through the entries with [param previous] and [param next] (actions: the
## shoulder buttons, the triggers), with their buttons named at either end of the row while the
## player is on the pad (PadHint). Polled, so a trigger — an axis — steps once per pull.
##
## [param move_focus]: step the focus instead, the entry being pressed with A.
func pad_navigation(previous: StringName, next: StringName, move_focus: bool = false) -> void:
	_pad_previous = previous
	_pad_next = next
	_step_focus = move_focus
	var before := PadHint.new(previous, font_size - 2)
	add_child(before)
	move_child(before, 0)
	add_child(PadHint.new(next, font_size - 2))


func _process(_delta: float) -> void:
	if _pad_previous == &"" or not is_visible_in_tree() or BindingCapture.listening or MenuFocus.modal:
		return
	var direction : int = 0
	if Input.is_action_just_pressed(_pad_previous):
		direction = -1
	elif Input.is_action_just_pressed(_pad_next):
		direction = 1
	if direction == 0:
		return
	if _step_focus:
		step_focus(direction)
	else:
		step(direction)


## Select the entry [param direction] places from the active one, round the ends, skipping hidden
## entries; the first one when none is active. Emits [signal selected], as a click does.
func step(direction: int) -> void:
	var keys : Array[StringName] = []
	for key: StringName in _buttons:
		if (_buttons[key] as Button).visible:
			keys.append(key)
	if keys.is_empty():
		return
	var at : int = keys.find(_active)
	var to : int = 0 if at < 0 else posmod(at + direction, keys.size())
	selected.emit(keys[to])


## Let the entries take the focus, so the cross, the stick or the arrows move along them and A or Enter
## presses one. The focused entry is drawn in the active amber, as under the pointer.
func allow_focus() -> void:
	_focusable = true
	for key: StringName in _buttons:
		(_buttons[key] as Button).focus_mode = Control.FOCUS_ALL


## Move the focus [param direction] entries along from the focused one (from the active one, or before
## the first, when none of them has it), round the ends.
func step_focus(direction: int) -> void:
	var visible_buttons : Array[Button] = []
	for key: StringName in _buttons:
		if (_buttons[key] as Button).visible:
			visible_buttons.append(_buttons[key])
	if visible_buttons.is_empty():
		return
	var at : int = visible_buttons.find(get_viewport().gui_get_focus_owner())
	if at < 0:
		at = visible_buttons.find(_buttons.get(_active))
	var to : int = (0 if direction > 0 else visible_buttons.size() - 1) if at < 0 \
			else posmod(at + direction, visible_buttons.size())
	visible_buttons[to].grab_focus()
	focus_stepped.emit()


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
