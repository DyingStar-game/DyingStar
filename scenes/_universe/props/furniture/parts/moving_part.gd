class_name MovingPart
extends ToggledPart

## A door or a drawer: open, its leaf (a mesh of the model, the parent by default) turns about its own
## origin -- the hinge -- and/or slides in its own frame. The same motion runs on the server and the
## clients: what the leaf carries (a door's body) blocks the way where the door stands.

## The node that moves: the door leaf or the drawer.
@export var leaf_path: NodePath = ^".."
## Hinge axis, in the leaf's own frame (a door: up).
@export var hinge_axis: Vector3 = Vector3.UP
## Angle (degrees) the leaf turns by when open, about [member hinge_axis]. 0 for a drawer.
@export_range(-180.0, 180.0, 1.0) var open_angle_deg: float = 0.0
## Offset (m) the leaf slides by when open, in its own frame. Zero for a door.
@export var open_slide: Vector3 = Vector3.ZERO
## Time (s) to open or close it fully.
@export_range(0.05, 3.0, 0.05) var duration_s: float = 0.6

var _leaf: Node3D
var _rest: Transform3D
## How far open it is shown: 0 shut, 1 open.
var _open: float = 0.0
var _tween: Tween


func _ready() -> void:
	super()
	_leaf = get_node_or_null(leaf_path) as Node3D
	if _leaf != null:
		_rest = _leaf.transform


## The leaf's pose [param t] of the way open (0 shut, 1 open), from its shut pose [param rest].
static func pose(rest: Transform3D, axis: Vector3, angle_deg: float, slide: Vector3, t: float) -> Transform3D:
	var basis: Basis = rest.basis
	if angle_deg != 0.0:
		basis = basis * Basis(axis.normalized(), deg_to_rad(angle_deg) * t)
	return Transform3D(basis, rest.origin + rest.basis * (slide * t))


func _show(on: bool, animate: bool) -> void:
	if _leaf == null:
		return
	var target: float = 1.0 if on else 0.0
	if _tween != null:
		_tween.kill()
	if not animate or not is_inside_tree():
		_set_open(target)
		return
	_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(_set_open, _open, target, duration_s * absf(target - _open))


func _set_open(t: float) -> void:
	_open = t
	_leaf.transform = pose(_rest, hinge_axis, open_angle_deg, open_slide, t)
