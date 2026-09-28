class_name StarMapViewCone
extends Control
## Where you are LOOKING, on the chart: a narrow translucent wedge from your marker, pointing the way
## your camera faces in the game. A heading, not a field of view: the full ~120° of the game camera
## covered half the towns around you and pointed at none of them.
##
## Drawn in 2D, over the chart, at a constant size on screen. A wedge laid on the ground in 3D shrank
## to nothing as soon as the view pulled back, which is exactly when you want to know which way you
## face. StarMap aims it every frame (aim / hide_cone); this node only draws.

## Length of the wedge on screen, in pixels.
const LENGTH_PX: float = 70.0
## Half its opening, in degrees: tight enough to read as a direction.
const HALF_ANGLE_DEG: float = 12.5
## Shown only at this ZOOM and closer, in metres (6 500 km). Past it the marker is a dot on a planet
## and a heading says nothing. The zoom, not the camera-to-marker distance: that is the figure the
## player reads on the chart.
const MAX_ZOOM_M: float = 6.5e6
const FILL: Color = Color(1.0, 0.35, 0.35, 0.28)  # StarMap.PLAYER_COLOR, faded
const EDGE: Color = Color(1.0, 0.35, 0.35, 0.8)

var _origin: Vector2 = Vector2.ZERO
var _direction: Vector2 = Vector2.ZERO
var _half_angle: float = 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false


## Show the wedge from [param origin] (screen pixels) toward [param direction] (screen space), opening
## [param half_angle] radians to each side.
func aim(origin: Vector2, direction: Vector2, half_angle: float = deg_to_rad(HALF_ANGLE_DEG)) -> void:
	if direction.length_squared() <= 0.0:
		hide_cone()
		return
	_origin = origin
	_direction = direction.normalized()
	_half_angle = half_angle
	visible = true
	queue_redraw()


func hide_cone() -> void:
	visible = false


func _draw() -> void:
	var left: Vector2 = _origin + _direction.rotated(-_half_angle) * LENGTH_PX
	var right: Vector2 = _origin + _direction.rotated(_half_angle) * LENGTH_PX
	draw_colored_polygon(PackedVector2Array([_origin, left, right]), FILL)
	draw_polyline(PackedVector2Array([left, _origin, right]), EDGE, 1.5, true)


## [param forward] with its part along [param up] removed: the direction you face on the ground, not
## the way the camera tilts. ZERO when looking straight up or down, where there is no such direction.
static func level_forward(forward: Vector3, up: Vector3) -> Vector3:
	var n: Vector3 = up.normalized()
	var flat: Vector3 = forward - n * forward.dot(n)
	return flat.normalized() if flat.length_squared() > 1e-8 else Vector3.ZERO
