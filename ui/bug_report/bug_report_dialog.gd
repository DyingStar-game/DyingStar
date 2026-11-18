class_name BugReportDialog
extends CanvasLayer
## The bug report form (BugReporter): a title, what happened, and whether the game's log goes with it.
## The capture was taken before the form opened; it is shown, small, so the player sees what is sent.
## Escape or "Cancel" closes it and nothing leaves.

## Emitted with the cleaned texts once they follow the rule (error_key).
signal submitted(title: String, description: String, with_log: bool)
## Closed without sending.
signal dismissed

## Above the HUD, like the place name dialog.
const LAYER := 20
const BACKDROP := Color(0.0, 0.0, 0.0, 0.6)
const WIDTH_PX := 640.0
const PREVIEW_HEIGHT_PX := 170.0
## What service-social accepts (createBugReportBody): the form says so before anything is sent.
const TITLE_MIN := 3
const TITLE_MAX := 80
const DESCRIPTION_MAX := 1500

var _title: LineEdit
var _description: TextEdit
var _with_log: CheckBox
var _preview: TextureRect
var _status: Label
var _send: Button
var _cancel: Button
var _can_send: bool = true
var _sending: bool = false


func _init() -> void:
	layer = LAYER
	visible = false
	_build()


## Open on empty fields, showing [param capture]. [param off_text] not empty: reports cannot be sent
## from here, the form says why and its Send button is off.
func open_with(capture: Texture2D, off_text: String = "") -> void:
	_title.text = ""
	_description.text = ""
	_preview.texture = capture
	_preview.visible = capture != null
	_can_send = off_text == ""
	set_sending(false)
	show_status(off_text)
	visible = true
	_title.grab_focus.call_deferred()


func close() -> void:
	_title.release_focus()
	_description.release_focus()
	visible = false


func is_open() -> bool:
	return visible


## While the report travels: the buttons wait, and Escape no longer closes the form.
func set_sending(on: bool) -> void:
	_sending = on
	_send.disabled = on or not _can_send
	_cancel.disabled = on
	_send.text = "%%MISSION_ACCEPTING" if on else "%%SVC_ACT_SEND_MESSAGE"


## A line under the fields: what is wrong with them, or why the report did not leave.
func show_status(text: String) -> void:
	_status.text = text
	_status.visible = text != ""


## What is wrong with a report's texts, as a localisation key; "" when they can be sent. Pure.
static func error_key(title: String, description: String) -> String:
	if title.strip_edges().length() < TITLE_MIN:
		return "%%BUG_REPORT_TITLE_SHORT"
	if description.strip_edges() == "":
		return "%%BUG_REPORT_DESCRIPTION_EMPTY"
	if description.strip_edges().length() > DESCRIPTION_MAX:
		return "%%BUG_REPORT_DESCRIPTION_LONG"
	return ""


## What to tell the player for [param key] (error_key).
static func error_text(key: String) -> String:
	var text := TranslationServer.translate(key)
	match key:
		"%%BUG_REPORT_TITLE_SHORT":
			return text % TITLE_MIN
		"%%BUG_REPORT_DESCRIPTION_LONG":
			return text % DESCRIPTION_MAX
	return text


func _input(event: InputEvent) -> void:
	# Before the GUI: Escape closes the form instead of opening the pause menu (as the place name dialog).
	if visible and (event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")):
		get_viewport().set_input_as_handled()
		if not _sending:
			_dismiss()


func _submit(_text: String = "") -> void:
	if _sending or not _can_send:
		return
	var key := error_key(_title.text, _description.text)
	if key != "":
		show_status(error_text(key))
		return
	submitted.emit(_title.text.strip_edges(), _description.text.strip_edges(), _with_log.button_pressed)


func _dismiss() -> void:
	close()
	dismissed.emit()


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
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)
	var heading := Label.new()
	heading.text = "%%BUG_REPORT_TITLE"
	ServiceStyle.font_of(heading, 20, true)
	heading.add_theme_color_override("font_color", ServiceStyle.ACCENT)
	column.add_child(heading)
	var intro := Label.new()
	intro.text = "%%BUG_REPORT_INTRO"
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ServiceStyle.font_of(intro, 14)
	intro.add_theme_color_override("font_color", ServiceStyle.TEXT)
	column.add_child(intro)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(0, PREVIEW_HEIGHT_PX)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	column.add_child(_preview)
	_title = LineEdit.new()
	_title.placeholder_text = "%%BUG_REPORT_TITLE_PLACEHOLDER"
	_title.max_length = TITLE_MAX
	_title.custom_minimum_size = Vector2(0, 40)
	ServiceStyle.apply_field(_title)
	_title.text_changed.connect(func(_t: String) -> void: _clear_error())
	_title.text_submitted.connect(func(_t: String) -> void: _description.grab_focus())
	column.add_child(_title)
	_description = TextEdit.new()
	_description.placeholder_text = "%%BUG_REPORT_DESCRIPTION_PLACEHOLDER"
	_description.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_description.custom_minimum_size = Vector2(0, 130)
	ServiceStyle.apply_textarea(_description)
	_description.text_changed.connect(_clear_error)
	column.add_child(_description)
	_with_log = CheckBox.new()
	_with_log.text = "%%BUG_REPORT_WITH_LOG"
	_with_log.button_pressed = true
	ServiceStyle.apply_check(_with_log)
	column.add_child(_with_log)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ServiceStyle.font_of(_status, 13)
	_status.add_theme_color_override("font_color", ServiceStyle.WARN)
	column.add_child(_status)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 10)
	column.add_child(buttons)
	_cancel = Button.new()
	_cancel.text = "%%SVC_ACT_CANCEL"
	ServiceStyle.apply_button(_cancel)
	_cancel.pressed.connect(_dismiss)
	buttons.add_child(_cancel)
	_send = Button.new()
	_send.text = "%%SVC_ACT_SEND_MESSAGE"
	ServiceStyle.apply_button(_send, true)
	_send.pressed.connect(_submit)
	buttons.add_child(_send)


## The player is fixing what the form complained about; a "cannot send from here" stays.
func _clear_error() -> void:
	if _can_send:
		show_status("")
