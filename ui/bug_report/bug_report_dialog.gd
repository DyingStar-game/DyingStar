class_name BugReportDialog
extends CanvasLayer
## The bug report form (BugReporter), on the QA team's template: a title and how bad it is, then what is
## wrong, how to get there, what happened and what should have. The capture was taken before the form
## opened, debug panels shown; it is displayed, small, so the player sees what is sent. Tab goes from
## one field to the next, in the template's order. Escape or "Cancel" closes it and nothing leaves.

## Emitted with the report ({title, severity, description, steps, actual, expected}, texts cleaned)
## once it follows the template (problem).
signal submitted(report: Dictionary, with_log: bool)
## Closed without sending.
signal dismissed

## Above the HUD, like the place name dialog.
const LAYER := 20
const BACKDROP := Color(0.0, 0.0, 0.0, 0.6)
## Two columns: the texts that take room on the left, the capture and the two results on the right.
const LEFT_PX := 520.0
const RIGHT_PX := 400.0
const PREVIEW_HEIGHT_PX := 150.0
const TITLE_MIN := 3
const TITLE_MAX := 80
## How bad the bug is, worst first: the key the report carries (service-social's BUG_SEVERITIES), the
## name the form shows and the colour of its round mark -- the one that opens the report's title in
## Discord (red, orange, yellow, purple), so the form and the QA channel speak the same.
const SEVERITIES: Array[Dictionary] = [
	{"key": "blocker", "label": "%%BUG_REPORT_SEVERITY_BLOCKER", "colour": Color("d32f2f")},
	{"key": "major", "label": "%%BUG_REPORT_SEVERITY_MAJOR", "colour": Color("f57c00")},
	{"key": "minor", "label": "%%BUG_REPORT_SEVERITY_MINOR", "colour": Color("fbc02d")},
	{"key": "cosmetic", "label": "%%BUG_REPORT_SEVERITY_COSMETIC", "colour": Color("9c27b0")},
]
## Side (px) of a severity's round mark in the list.
const MARK_PX := 14
## The one a form opens on: most reports are of something annoying one can play around.
const DEFAULT_SEVERITY := "minor"
## The template's parts, in the order they are asked and checked: the key the report carries them
## under, their label, their placeholder, the most they may hold (what service-social accepts,
## createBugReportBody: the four together fit one Discord message) and their height in the form (px).
const PARTS: Array[Dictionary] = [
	{"key": "description", "label": "%%BUG_REPORT_DESCRIPTION", "hint": "%%BUG_REPORT_DESCRIPTION_HINT",
		"max": 1000, "height": 78.0},
	{"key": "steps", "label": "%%BUG_REPORT_STEPS", "hint": "%%BUG_REPORT_STEPS_HINT", "max": 1500, "height": 130.0},
	{"key": "actual", "label": "%%BUG_REPORT_ACTUAL", "hint": "%%BUG_REPORT_ACTUAL_HINT", "max": 700, "height": 70.0},
	{"key": "expected", "label": "%%BUG_REPORT_EXPECTED", "hint": "%%BUG_REPORT_EXPECTED_HINT", "max": 700,
		"height": 70.0},
]
## The parts shown under the title; the others go under the capture.
const LEFT_PARTS: Array[String] = ["description", "steps"]

var _title: LineEdit
var _severity: OptionButton
## The template's fields, by the key of their part.
var _fields: Dictionary = {}
var _with_log: CheckBox
var _preview: TextureRect
var _status: Label
var _send: Button
var _cancel: Button
var _can_send: bool = true
var _sending: bool = false
## What MenuFocus.modal was when the form opened, given back when it closes.
var _menus_were_modal: bool = false


func _init() -> void:
	layer = LAYER
	visible = false
	_build()


## Open on empty fields, showing [param capture]. [param off_text] not empty: reports cannot be sent
## from here, the form says why and its Send button is off. [param log_path]: where the log the
## checkbox attaches is, shown when it is hovered.
func open_with(capture: Texture2D, off_text: String = "", log_path: String = "") -> void:
	_title.text = ""
	_severity.select(severity_index(DEFAULT_SEVERITY))
	for key: String in _fields:
		(_fields[key] as TextEdit).text = ""
	_preview.texture = capture
	_with_log.tooltip_text = log_path
	_can_send = off_text == ""
	set_sending(false)
	show_status(off_text)
	if not visible:
		# Over a menu as over the world: the menus leave the keys to the form (MenuFocus.modal, as for a
		# pad popup), and the form is the last under its parent -- the first asked about a key (_input).
		_menus_were_modal = MenuFocus.modal
		MenuFocus.modal = true
		if get_parent() != null:
			get_parent().move_child(self, -1)
	visible = true
	_title.grab_focus.call_deferred()


func close() -> void:
	var focused: Control = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focused != null and is_ancestor_of(focused):
		focused.release_focus()
	if visible:
		MenuFocus.modal = _menus_were_modal
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


## The report as typed: its title, how bad it is and the template's parts, spaces around the texts
## taken off.
func report() -> Dictionary:
	var out: Dictionary = {
		"title": _title.text.strip_edges(),
		"severity": str(SEVERITIES[maxi(_severity.selected, 0)]["key"]),
	}
	for key: String in _fields:
		out[key] = (_fields[key] as TextEdit).text.strip_edges()
	return out


## A round mark of [param colour], MARK_PX wide, its edge softened.
static func mark_of(colour: Color) -> Texture2D:
	var image := Image.create_empty(MARK_PX, MARK_PX, false, Image.FORMAT_RGBA8)
	var radius: float = MARK_PX * 0.5
	for y: int in MARK_PX:
		for x: int in MARK_PX:
			var off: float = Vector2(x + 0.5 - radius, y + 0.5 - radius).length()
			image.set_pixel(x, y, Color(colour, clampf(radius - off, 0.0, 1.0)))
	return ImageTexture.create_from_image(image)


## Where [param key] stands in SEVERITIES, -1 when it is not one of them.
static func severity_index(key: String) -> int:
	for i: int in SEVERITIES.size():
		if SEVERITIES[i]["key"] == key:
			return i
	return -1


## What keeps [param typed] (report) from being sent, {} when nothing does: {"key"} for a title too
## short, {"key", "label"} for a part left empty, {"key", "label", "max"} for one too long. The first
## found, in the template's order. Pure.
static func problem(typed: Dictionary) -> Dictionary:
	if str(typed.get("title", "")).strip_edges().length() < TITLE_MIN:
		return {"key": "%%BUG_REPORT_TITLE_SHORT"}
	for part: Dictionary in PARTS:
		var text: String = str(typed.get(part["key"], "")).strip_edges()
		if text == "":
			return {"key": "%%BUG_REPORT_PART_EMPTY", "label": part["label"]}
		if text.length() > int(part["max"]):
			return {"key": "%%BUG_REPORT_PART_LONG", "label": part["label"], "max": part["max"]}
	return {}


## What to tell the player for [param found] (problem).
static func problem_text(found: Dictionary) -> String:
	var text := TranslationServer.translate(str(found.get("key", "")))
	var label := str(TranslationServer.translate(str(found.get("label", ""))))
	match str(found.get("key", "")):
		"%%BUG_REPORT_TITLE_SHORT":
			return text % TITLE_MIN
		"%%BUG_REPORT_PART_EMPTY":
			return text % label
		"%%BUG_REPORT_PART_LONG":
			return text % [label, int(found.get("max", 0))]
	return text


func _input(event: InputEvent) -> void:
	if not visible:
		return
	# Before the GUI and before whatever is under the form: Escape closes the form instead of the menu
	# or the DataPad behind it (as the place name dialog), and Tab walks the form's fields instead of
	# being the chat's or the chart's key.
	if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if not _sending:
			_dismiss()
	elif event.is_action_pressed("ui_focus_next", true, true):
		get_viewport().set_input_as_handled()
		walk_focus(false)
	elif event.is_action_pressed("ui_focus_prev", true, true):
		get_viewport().set_input_as_handled()
		walk_focus(true)


## Tab ([param back]: Shift + Tab): the keyboard goes to the next field of the form, in the template's
## order, round and round; to the title when it was nowhere in the form.
func walk_focus(back: bool) -> void:
	var from: Control = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if from == null or not is_ancestor_of(from):
		_title.grab_focus()
		return
	var to: Control = from.find_prev_valid_focus() if back else from.find_next_valid_focus()
	if to != null and is_ancestor_of(to):
		to.grab_focus()


func _submit() -> void:
	if _sending or not _can_send:
		return
	var typed: Dictionary = report()
	var found: Dictionary = problem(typed)
	if not found.is_empty():
		show_status(problem_text(found))
		return
	submitted.emit(typed, _with_log.button_pressed)


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
	column.add_child(_caption("%%BUG_REPORT_INTRO", ServiceStyle.TEXT, 14))
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 20)
	column.add_child(columns)
	var left := _side(columns, LEFT_PX)
	var right := _side(columns, RIGHT_PX)
	_title = LineEdit.new()
	_title.placeholder_text = "%%BUG_REPORT_TITLE_PLACEHOLDER"
	_title.max_length = TITLE_MAX
	_title.custom_minimum_size = Vector2(0, 40)
	ServiceStyle.apply_field(_title)
	_title.text_changed.connect(func(_t: String) -> void: _clear_error())
	_title.text_submitted.connect(func(_t: String) -> void: (_fields[PARTS[0]["key"]] as TextEdit).grab_focus())
	left.add_child(_title)
	# On its own line, under the title: beside it, the title had no room left to be read.
	var grade := HBoxContainer.new()
	grade.add_theme_constant_override("separation", 10)
	left.add_child(grade)
	var grade_label := _caption("%%BUG_REPORT_SEVERITY", ServiceStyle.TEXT, 13)
	grade_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	ServiceStyle.font_of(grade_label, 13, true)
	grade.add_child(grade_label)
	_severity = OptionButton.new()
	_severity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for severity: Dictionary in SEVERITIES:
		_severity.add_icon_item(mark_of(severity["colour"]), str(severity["label"]))
	_severity.tooltip_text = "%%BUG_REPORT_SEVERITY_TIP"
	_severity.custom_minimum_size = Vector2(0, 40)
	ServiceStyle.apply_option(_severity)
	grade.add_child(_severity)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(0, PREVIEW_HEIGHT_PX)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	right.add_child(_preview)
	right.add_child(_caption("%%BUG_REPORT_CAPTURE", ServiceStyle.MUTED, 12))
	for part: Dictionary in PARTS:
		_add_part(left if LEFT_PARTS.has(part["key"]) else right, part)
	_with_log = CheckBox.new()
	_with_log.text = "%%BUG_REPORT_WITH_LOG"
	_with_log.button_pressed = true
	ServiceStyle.apply_check(_with_log)
	column.add_child(_with_log)
	_status = _caption("", ServiceStyle.WARN, 13)
	_status.custom_minimum_size = Vector2(0, 20)  # its line is kept: the form does not jump when it speaks
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


## One of the form's two columns, [param width] px wide, under [param columns].
func _side(columns: HBoxContainer, width: float) -> VBoxContainer:
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(width, 0)
	side.add_theme_constant_override("separation", 6)
	columns.add_child(side)
	return side


## A wrapped line of text.
func _caption(text: String, colour: Color, size: int) -> Label:
	var line := Label.new()
	line.text = text
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ServiceStyle.font_of(line, size)
	line.add_theme_color_override("font_color", colour)
	return line


## The label and the field of one part of the template, in [param side].
func _add_part(side: VBoxContainer, part: Dictionary) -> void:
	var label := _caption(str(part["label"]), ServiceStyle.TEXT, 13)
	ServiceStyle.font_of(label, 13, true)
	side.add_child(label)
	var field := TextEdit.new()
	field.placeholder_text = str(part["hint"])
	field.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	field.tab_input_mode = false  # Tab goes to the next field, as in any form: no tab is typed in a report
	field.custom_minimum_size = Vector2(0, float(part["height"]))
	ServiceStyle.apply_textarea(field)
	field.text_changed.connect(_clear_error)
	side.add_child(field)
	_fields[part["key"]] = field


## The player is fixing what the form complained about; a "cannot send from here" stays.
func _clear_error() -> void:
	if _can_send:
		show_status("")
