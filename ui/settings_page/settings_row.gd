class_name SettingsRow
extends PanelContainer
## One line of a settings page, lit while the pointer is anywhere over it.
##
## On a wide screen the label sits far left and its control far right, with nothing joining them:
## only the small On/Off button reacted, so there was no telling which setting you were about to
## change. The controls page already reads well for this exact reason — each of its lines IS a
## button, so the whole row highlights.

var _idle : StyleBoxFlat
var _hover : StyleBoxFlat


## Wrap every direct HBoxContainer child of `rows` so it lights up on hover. Done from code rather
## than authored into each scene: three pages and twenty-odd lines share one behaviour, and a new
## setting inherits it without anyone remembering to.
##
## Call it AFTER the page has resolved its own node paths — this reparents, so a path like
## "ShowDebug/Button" gains a level and would no longer resolve.
static func wrap_rows(rows: Container) -> void:
	for child in rows.get_children():
		if not (child is HBoxContainer):
			continue
		var row := SettingsRow.new()
		var at : int = child.get_index()
		rows.remove_child(child)
		row.add_child(child)
		rows.add_child(row)
		rows.move_child(row, at)


func _ready() -> void:
	_idle = _style(Color(0.0, 0.0, 0.0, 0.0))
	_hover = _style(SettingsStyle.HOVER_COLOR)
	add_theme_stylebox_override("panel", _idle)
	# PASS, not STOP: the button and sliders inside must still get their clicks.
	mouse_filter = Control.MOUSE_FILTER_PASS
	# The children that consume the mouse (buttons, sliders) steal the hover from us, so listen to
	# them too — otherwise the highlight would vanish exactly when the pointer reaches the control.
	_watch(self)
	for node in find_children("*", "Control", true, false):
		_watch(node as Control)


func _watch(control: Control) -> void:
	control.mouse_entered.connect(_on_enter)
	control.mouse_exited.connect(_on_exit)


func _on_enter() -> void:
	add_theme_stylebox_override("panel", _hover)


func _on_exit() -> void:
	# Crossing from the row onto a control inside it fires exit-then-enter in no fixed order, which
	# would flicker. Only really leave once the pointer is outside the whole row.
	if get_global_rect().has_point(get_global_mouse_position()):
		return
	add_theme_stylebox_override("panel", _idle)


## No content margins: a highlight must not move the row it highlights.
static func _style(color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_content_margin_all(0)
	return box
