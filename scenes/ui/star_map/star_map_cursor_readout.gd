class_name StarMapCursorReadout
extends Control

## Longitude, latitude and height of the ground under the cursor, written beside it.
##
## A drawing over the chart, like the scale bar: it never takes a click. It stands on a dark plate:
## over a starfield light text reads alone, over sunlit ground it did not, outline and all. The chart
## says what to write and where ([method show_at]); this only writes it, and keeps it on screen.

## Where the text starts, from the cursor's tip: down and to the right, clear of the arrow.
const OFFSET: Vector2 = Vector2(18.0, 30.0)
const TEXT_COLOR: Color = Color(0.95, 0.96, 0.99, 1.0)
const PLATE_COLOR: Color = Color(0.04, 0.05, 0.07, 0.82)
## Room between the text and the plate's edge, across and up and down.
const PADDING: Vector2 = Vector2(8.0, 4.0)
const CORNER_RADIUS: int = 4

var _plate := StyleBoxFlat.new()

var _text: String = ""
var _at: Vector2 = Vector2.ZERO


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_plate.bg_color = PLATE_COLOR
	_plate.set_corner_radius_all(CORNER_RADIUS)


## Write [param text] beside the cursor at [param cursor].
func show_at(cursor: Vector2, text: String) -> void:
	if text == _text and cursor == _at and visible:
		return
	_text = text
	_at = cursor
	visible = true
	queue_redraw()


func hide_readout() -> void:
	if visible:
		visible = false


func _draw() -> void:
	if _text == "":
		return
	var font: Font = get_theme_default_font()
	var font_size: int = get_theme_default_font_size()
	var span: Vector2 = font.get_string_size(_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var at: Vector2 = place(_at, span + PADDING * 2.0, size) + Vector2(PADDING.x, -PADDING.y)
	var top: float = at.y - font.get_ascent(font_size)
	draw_style_box(_plate, Rect2(Vector2(at.x, top) - PADDING, span + PADDING * 2.0))
	draw_string(font, at, _text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, TEXT_COLOR)


## Where a text [param span] wide and high starts (its baseline) for a cursor at [param cursor], kept
## inside [param area]: beside the cursor, or on its other side near the right or bottom edge.
static func place(cursor: Vector2, span: Vector2, area: Vector2) -> Vector2:
	var at: Vector2 = cursor + OFFSET
	if at.x + span.x > area.x:
		at.x = cursor.x - OFFSET.x - span.x
	if at.y > area.y:
		at.y = cursor.y - OFFSET.y + span.y
	return Vector2(maxf(at.x, 0.0), maxf(at.y, span.y))
