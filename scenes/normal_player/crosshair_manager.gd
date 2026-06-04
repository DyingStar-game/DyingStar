class_name CrosshairManager extends Control
#
# Reusable manager for on-demand aim crosshairs (overlays shown depending on the
# context: aiming, weapon, tool...), IN ADDITION to the permanent small dot
# (which stays handled separately in player_ui).
#
# Usage:
#   var cm := CrosshairManager.new()
#   parent.add_child(cm)              # ideally inside a CenterContainer (screen-centered)
#   cm.register("aim", _my_function)  # add a custom style (optional)
#   cm.set_style("aim")               # show a style
#   cm.clear()                        # show nothing
#
# A "style" is a Callable that receives the CanvasItem to draw on, centered on
# Vector2.ZERO (= screen center if the manager is inside a CenterContainer).

var _styles: Dictionary = {}   # name:String -> Callable(canvas: CanvasItem)
var _current: String = ""

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# built-in styles
	register("aim", _draw_aim_star)

## Register (or replace) a crosshair style.
func register(style_name: String, draw_fn: Callable) -> void:
	_styles[style_name] = draw_fn

## Show the given style ("" = none).
func set_style(style_name: String) -> void:
	if style_name == _current:
		return
	_current = style_name
	queue_redraw()

## Show no overlay crosshair.
func clear() -> void:
	set_style("")

func _draw() -> void:
	if _current != "" and _styles.has(_current):
		_styles[_current].call(self)

# ── Built-in styles ─────────────────────────────────────────────────────────

## "Star/sun" crosshair: center dot + rays + 4 cardinal lines.
func _draw_aim_star(canvas: CanvasItem) -> void:
	var col := Color(1, 1, 1, 0.9)
	var center := Vector2.ZERO
	canvas.draw_circle(center, 3.0, col)
	var rays := 28
	var inner := 9.0
	var outer := 20.0
	for i in rays:
		var a := TAU * float(i) / float(rays)
		var dir := Vector2(cos(a), sin(a))
		canvas.draw_line(dir * inner, dir * outer, col, 1.5)
	for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		canvas.draw_line(d * (outer + 3.0), d * (outer + 16.0), col, 2.0)
