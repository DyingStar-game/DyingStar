class_name StarMapPins
extends Control

## The chart's two points on the ground, Google Maps' way: the PIN a plain click drops to read where it
## is (gone as soon as the view moves or anything else is done), and the MARKER the context menu sets,
## which stays until the menu takes it away. Each is a point of a body -- a unit direction in its own
## frame -- shown as the cursor readout is (StarMapCursorReadout): a cross on the spot and its numbers.
##
## Knows nothing of the chart: it is told where each point is on screen and what to write (refresh).

## A point: {"body": index into the chart's bodies, "local": unit direction in the body's frame}.
var pin: Dictionary = {}
var marker: Dictionary = {}

var _pin_view := StarMapCursorReadout.new()
var _marker_view := StarMapCursorReadout.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_pin_view)
	add_child(_marker_view)


## Draw both from [param where] (a point -> its screen position, or null when it is not in view) and
## [param text] (a point -> what it says).
func refresh(where: Callable, text: Callable) -> void:
	_show(_pin_view, pin, where, text)
	_show(_marker_view, marker, where, text, "%%HUD_MAP_MARKER")


func clear_pin() -> void:
	pin = {}


static func _show(view: StarMapCursorReadout, point: Dictionary, where: Callable, text: Callable,
		title: String = "") -> void:
	if point.is_empty():
		view.hide_readout()
		return
	var at: Variant = where.call(point)
	if at == null:
		view.hide_readout()
		return
	view.show_at(at as Vector2, str(text.call(point)), true,
			TranslationServer.translate(title) if title != "" else "")
