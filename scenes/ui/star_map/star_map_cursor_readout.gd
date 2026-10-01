class_name StarMapCursorReadout
extends Control

## Longitude, latitude and height of the ground under the cursor, written beside it.
##
## A drawing over the chart, like the scale bar: it never takes a click, and it is drawn twice, a dark
## fat pass then the light one, because it lies over a starfield in places and over a lit planet in
## others. The chart says what to write and where ([method show_at]); this only writes it, and keeps
## it on screen.

## Where the text starts, from the cursor's tip: down and to the right, clear of the arrow.
const OFFSET: Vector2 = Vector2(18.0, 30.0)
const TEXT_COLOR: Color = Color(0.92, 0.94, 0.98, 0.95)
const OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)

var _text: String = ""
var _at: Vector2 = Vector2.ZERO


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


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
	var at: Vector2 = place(_at, span, size)
	draw_string_outline(font, at, _text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, OUTLINE_COLOR)
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
