class_name PlaceNameDialog
extends CanvasLayer
## The discoverer of a place is asked for its name (PlaceWatcher): one field, "Propose" and "Later". The rule a
## name must follow (PlaceNameRule) is checked here first, so the player reads what is wrong before anything
## is sent; the server checks it again. Escape or "Later" closes it until the next visit.

## Emitted with the cleaned name once it follows the rule.
signal proposed(name: String)
## Closed without a name.
signal dismissed

## Above the HUD, like the controls help.
const LAYER := 20
const BACKDROP := Color(0.0, 0.0, 0.0, 0.6)
const WIDTH_PX := 520.0
## What ARES asks, per kind of place.
const PROMPT_KEYS := {"cave": "%%PLACE_NAME_PROMPT_CAVE"}

var _prompt: Label
var _field: LineEdit
var _error: Label


func _init() -> void:
	layer = LAYER
	visible = false
	_build()


## Open for a place of kind [param kind], the field empty and focused.
func open_for(kind: String) -> void:
	_prompt.text = tr(str(PROMPT_KEYS.get(kind, PROMPT_KEYS["cave"])))
	_field.text = ""
	_error.text = ""
	visible = true
	_field.grab_focus.call_deferred()


func close() -> void:
	_field.release_focus()
	visible = false


func _input(event: InputEvent) -> void:
	# Before the GUI: Escape closes the dialog instead of opening the pause menu (as in the chat).
	if visible and (event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")):
		get_viewport().set_input_as_handled()
		_dismiss()


func _submit(_text: String = "") -> void:
	var key := PlaceNameRule.error_key(_field.text)
	if key != "":
		_error.text = error_text(key)
		return
	close()
	proposed.emit(PlaceNameRule.clean(_field.text))


func _dismiss() -> void:
	close()
	dismissed.emit()


## What to tell the player for the rule's [param key] (PlaceNameRule.error_key).
static func error_text(key: String) -> String:
	var text := TranslationServer.translate(key)
	match key:
		"%%PLACE_NAME_TOO_SHORT":
			return text % PlaceNameRule.MIN_LENGTH
		"%%PLACE_NAME_TOO_LONG":
			return text % PlaceNameRule.MAX_LENGTH
	return text


func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var veil := ColorRect.new()
	veil.color = BACKDROP
	veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(veil)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(WIDTH_PX, 0)
	ServiceStyle.apply_frame(frame)
	center.add_child(frame)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	frame.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	margin.add_child(column)
	var title := Label.new()
	title.text = "%%PLACE_NAME_TITLE"
	ServiceStyle.font_of(title, 20, true)
	title.add_theme_color_override("font_color", ServiceStyle.ACCENT)
	column.add_child(title)
	_prompt = Label.new()
	_prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ServiceStyle.font_of(_prompt, 15)
	_prompt.add_theme_color_override("font_color", ServiceStyle.TEXT)
	column.add_child(_prompt)
	_field = LineEdit.new()
	_field.placeholder_text = "%%PLACE_NAME_PLACEHOLDER"
	_field.max_length = PlaceNameRule.MAX_LENGTH + 10  # room to see the "too long" message, not a hard stop
	_field.custom_minimum_size = Vector2(0, 40)
	ServiceStyle.apply_field(_field)
	_field.text_submitted.connect(_submit)
	_field.text_changed.connect(func(_t: String) -> void: _error.text = "")
	column.add_child(_field)
	_error = Label.new()
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ServiceStyle.font_of(_error, 13)
	_error.add_theme_color_override("font_color", ServiceStyle.WARN)
	column.add_child(_error)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 10)
	column.add_child(buttons)
	var later := Button.new()
	later.text = "%%PLACE_NAME_LATER"
	ServiceStyle.apply_button(later)
	later.pressed.connect(_dismiss)
	buttons.add_child(later)
	var propose := Button.new()
	propose.text = "%%PLACE_NAME_PROPOSE"
	ServiceStyle.apply_button(propose, true)
	propose.pressed.connect(_submit)
	buttons.add_child(propose)
