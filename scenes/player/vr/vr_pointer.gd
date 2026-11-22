class_name VrPointer
extends Node
## In VR the right hand aims, not the head: the player's interaction ray (InteractRay -- door handles,
## seats, crates, consoles, 3D screens) leaves from the right controller's aim pose; a dot shows where it
## meets something to use, and the controller ticks as it comes onto it. No beam: the dot and the tick
## were enough, the beam only cluttered the view (playtest 2026-11-22). On the flat screen the
## crosshair at the middle of the screen is what aims; in a headset the middle of the view is nowhere the
## eyes can see, and nothing showed what the ray met: a truck's handle could not be found (2026-11-22).
##
## While the right controller is not tracked (put down, out of sight of the headset) the ray goes back to
## the head, as on the flat screen. While a menu has the mouse, XRScreen's laser points instead.
##
## Built by VrRig for the owner's player, in VR only.

## Radius (m) of the dot where the ray meets what it aims at.
const DOT_M := 0.012
## The dot's colour.
const HIT_COLOUR := Color(0.55, 0.95, 1.0, 0.9)
## The tick in the controller as the ray comes onto something (Hz, 0..1, s).
const TICK_HZ := 160.0
const TICK_AMPLITUDE := 0.25
const TICK_S := 0.02

## Does the game have the mouse captured (the view is the player's, no menu)? A Callable for the tests.
var mouse_captured: Callable = func() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

var _ray: RayCast3D = null
var _aim: XRController3D = null
var _head: Node3D = null
var _dot: MeshInstance3D = null
var _was_hit: bool = false


## Aim [param ray] from [param aim] (the right hand's aim pose), or from [param head] when the hand is
## not tracked.
func setup(ray: RayCast3D, aim: XRController3D, head: Node3D) -> void:
	_ray = ray
	_aim = aim
	_head = head
	var ball := SphereMesh.new()
	ball.radius = DOT_M
	ball.height = DOT_M * 2.0
	ball.radial_segments = 12
	ball.rings = 6
	ball.material = _paint(HIT_COLOUR)
	_dot = _shape("AimDot", ball)
	aim.add_child(_dot)


func _process(_delta: float) -> void:
	if not is_instance_valid(_ray) or not is_instance_valid(_aim):
		return
	var on_hand: bool = _aim.get_has_tracking_data()
	var from: Node3D = _aim if on_hand else _head
	if _ray.get_parent() != from:
		_ray.reparent(from, false)
	var hit: bool = on_hand and mouse_captured.call() and _ray.is_colliding()
	if hit:
		_dot.global_position = _ray.get_collision_point()
	_dot.visible = hit
	if hit and not _was_hit:
		_aim.trigger_haptic_pulse(&"haptic", TICK_HZ, TICK_AMPLITUDE, TICK_S, 0.0)
	_was_hit = hit


static func _paint(colour: Color) -> StandardMaterial3D:
	var paint := StandardMaterial3D.new()
	paint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	paint.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	paint.albedo_color = colour
	return paint


static func _shape(node_name: String, mesh: Mesh) -> MeshInstance3D:
	var shape := MeshInstance3D.new()
	shape.name = node_name
	shape.mesh = mesh
	shape.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shape.visible = false
	return shape
