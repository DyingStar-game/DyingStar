class_name StarMapScale
extends Control

## The graphic scale bar, bottom left: a bar of a round length, with what that length is.
##
## A chart that spans from a kilometre to sixteen astronomical units cannot be read without one. The
## readout says how far the camera is, which is a different question from how big the thing on screen
## is, and that second question is the one you ask when looking at a planet.
##
## ⚠️ Like every scale bar over a perspective view, it is exact only at the DEPTH OF THE SUBJECT. Ground
## nearer the camera than the body's centre reads slightly long, ground beyond it slightly short. That
## is inherent, it is what paper maps of globes do too, and the alternative — no scale at all — is worse.

## Length the bar aims for on screen, in pixels, before being rounded to a speakable distance.
const TARGET_WIDTH: float = 190.0
## Tick heights, and the room left under the label.
const END_TICK: float = 7.0
const MID_TICK: float = 4.0
const LABEL_GAP: float = 5.0

const BAR_COLOR: Color = Color(0.92, 0.94, 0.98, 0.92)
const OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)

var _length_m: float = 0.0
var _width_px: float = 0.0


func _init() -> void:
	# It is a drawing, not a target: it must never take a click meant for a body behind it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Tell the bar how much ground one pixel covers. Everything else follows.
func set_ground_scale(metres_per_pixel: float) -> void:
	if metres_per_pixel <= 0.0 or not is_finite(metres_per_pixel):
		_width_px = 0.0
		queue_redraw()
		return
	_length_m = nice_length(TARGET_WIDTH * metres_per_pixel)
	_width_px = _length_m / metres_per_pixel
	queue_redraw()


## The nearest round distance at or below [param metres]: 1, 2 or 5 times a power of ten.
##
## Round in the sense a reader means it, not in the sense a float does. "187 km" on a scale bar is
## noise — the bar exists to be measured against by eye, and the eye can only do that with numbers it
## can halve and double.
static func nice_length(metres: float) -> float:
	if metres <= 0.0 or not is_finite(metres):
		return 0.0
	var decade: float = pow(10.0, floorf(log(metres) / log(10.0)))
	var mantissa: float = metres / decade
	var step: float = 1.0
	if mantissa >= 5.0:
		step = 5.0
	elif mantissa >= 2.0:
		step = 2.0
	return step * decade


## Metres, kilometres, or thousands of kilometres — written out rather than pushed through
## [code]Globals.format_distance[/code], which says "million km" in English whatever the language.
static func label_for(metres: float) -> String:
	if metres < 1000.0:
		return "%d m" % int(round(metres))
	return "%s km" % Globals.format_thousands(metres / 1000.0)


func _draw() -> void:
	if _width_px <= 0.0:
		return
	var font: Font = get_theme_default_font()
	var font_size: int = get_theme_default_font_size()
	var base: float = size.y - 2.0
	var bar: PackedVector2Array = PackedVector2Array([
		Vector2(0.0, base - END_TICK), Vector2(0.0, base),
		Vector2(_width_px, base), Vector2(_width_px, base - END_TICK),
	])
	# Drawn twice, the dark pass fatter: the bar sits over a starfield in places and over a lit planet
	# in others, and one colour cannot be read on both.
	draw_polyline(bar, OUTLINE_COLOR, 3.0)
	draw_polyline(bar, BAR_COLOR, 1.0)
	draw_line(Vector2(_width_px * 0.5, base), Vector2(_width_px * 0.5, base - MID_TICK),
			OUTLINE_COLOR, 3.0)
	draw_line(Vector2(_width_px * 0.5, base), Vector2(_width_px * 0.5, base - MID_TICK),
			BAR_COLOR, 1.0)

	var text: String = label_for(_length_m)
	var text_width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var at := Vector2(maxf((_width_px - text_width) * 0.5, 0.0), base - END_TICK - LABEL_GAP)
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, OUTLINE_COLOR)
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, BAR_COLOR)
