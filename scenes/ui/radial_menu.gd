class_name RadialMenu
extends Control

# Generic text-based radial (wheel) menu, reusable by any dev.
# Usage:
#   var wheel := RadialMenu.new()
#   some_canvaslayer.add_child(wheel)
#   wheel.option_selected.connect(func(data): ...)
#   # hold a key:
#   wheel.open([{ "text": "Rock", "data": "rock" }, { "text": "Box", "data": "box" }])
#   # on release:
#   wheel.confirm()
# Move the mouse toward a slice to highlight it; confirm() emits option_selected(data)
# for the highlighted slice (or cancelled if none/center).

signal option_selected(data)
signal cancelled

@export var radius: float = 170.0
@export var inner_radius: float = 60.0
@export var font_size: int = 22
@export var title: String = ""

var _options: Array = []
var _selected: int = -1

func _ready() -> void:
	# Independent of the parent's transform so the wheel always sits in viewport space.
	top_level = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	set_process(false)

## Open the wheel with a list of { "text": String, "data": Variant } entries.
func open(options: Array) -> void:
	_options = options
	_selected = -1
	visible = true
	set_process(true)
	queue_redraw()

func close() -> void:
	visible = false
	set_process(false)

## Emit the highlighted option (or cancelled) and close.
func confirm() -> void:
	if _selected >= 0 and _selected < _options.size():
		option_selected.emit(_options[_selected].get("data"))
	else:
		cancelled.emit()
	close()

func _process(_delta: float) -> void:
	var center := get_viewport_rect().size / 2.0
	var v := get_local_mouse_position() - center
	if _options.is_empty() or v.length() < inner_radius:
		_selected = -1
	else:
		# Angle with 0 at the top, increasing clockwise, snapped to the nearest slice.
		var ang := wrapf(atan2(v.x, -v.y), 0.0, TAU)
		_selected = int(round(ang / TAU * _options.size())) % _options.size()
	queue_redraw()

func _draw() -> void:
	if _options.is_empty():
		return
	var center := get_viewport_rect().size / 2.0
	var font := get_theme_default_font()
	# Dim circular backdrop.
	draw_circle(center, radius + 16.0, Color(0.0, 0.0, 0.0, 0.55))
	draw_circle(center, inner_radius, Color(0.0, 0.0, 0.0, 0.5))
	var n := _options.size()
	for i in n:
		var a := float(i) / n * TAU - PI / 2.0
		var pos := center + Vector2(cos(a), sin(a)) * ((radius + inner_radius) / 2.0)
		var text: String = str(_options[i].get("text", ""))
		var col := Color(1, 1, 1)
		if i == _selected:
			col = Color(1.0, 0.85, 0.2)
			draw_circle(pos, font_size * 1.7, Color(1, 1, 1, 0.18))
		var ts := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		font.draw_string(get_canvas_item(), pos - Vector2(ts.x / 2.0, -font_size / 3.0),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
	# Title / current selection in the center.
	var center_text := title
	if _selected >= 0:
		center_text = str(_options[_selected].get("text", ""))
	if center_text != "":
		var cts := font.get_string_size(center_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		font.draw_string(get_canvas_item(), center - Vector2(cts.x / 2.0, -font_size / 3.0),
			center_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1, 1, 1))
