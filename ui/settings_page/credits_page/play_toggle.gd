class_name PlayToggle
extends Button
## A small play / stop button that draws its own sign: a triangle while stopped, a square while its track
## plays. Drawn, not typed: the menu's font (Poppins) has no ▶ or ■, and a fallback font differs from one
## system to the next.

## Width and height of the button, in pixels.
const SIDE_PX : float = 22.0

## True while its track plays: the button shows the stop square and offers to stop.
var playing : bool = false:
	set(value):
		playing = value
		tooltip_text = "%%MENU_CREDITS_STOP" if value else "%%MENU_CREDITS_LISTEN"
		queue_redraw()


func _init() -> void:
	flat = true
	# The credit line takes the focus (cross, stick, arrows); the button only answers the pointer.
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(SIDE_PX, SIDE_PX)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	tooltip_text = "%%MENU_CREDITS_LISTEN"


func _draw() -> void:
	var color : Color = get_theme_color("font_hover_color" if is_hovered() else "font_color", "Button")
	var centre : Vector2 = size * 0.5
	var r : float = minf(size.x, size.y) * 0.3
	if playing:
		draw_rect(Rect2(centre - Vector2(r, r) * 0.8, Vector2(r, r) * 1.6), color)
	else:
		draw_colored_polygon(PackedVector2Array([
			centre + Vector2(-r * 0.7, -r), centre + Vector2(-r * 0.7, r), centre + Vector2(r, 0.0),
		]), color)
