class_name MovingPart
extends ToggledPart

## A door or a drawer: open, its leaf (a mesh of the model, the parent by default) turns about its own
## origin -- the hinge -- and/or slides in its own frame. The same motion runs on the server and the
## clients: what the leaf carries (a door's body) blocks the way where the door stands.

## Opened by the server for an NPC living in its home (SpawnBuilding.server_open_for_npc): the door it
## goes out by -- an NPC never opens one itself.
@export var opens_for_npc: bool = false
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
## A latch that turns before the leaf moves (a container door's handle), the leaf waiting for it; empty
## for none. It turns about its own origin, by [member latch_angle_deg] about [member latch_axis].
@export var latch_path: NodePath
## The latch's axis, in its own frame.
@export var latch_axis: Vector3 = Vector3.FORWARD
## Angle (degrees) the latch turns by before the leaf opens.
@export_range(-180.0, 180.0, 1.0) var latch_angle_deg: float = -90.0
## Share of the motion the latch takes, at the start of an opening (the end of a closing).
@export_range(0.0, 0.9, 0.05) var latch_share: float = 0.3
## Heard as it opens (a live change, not its state on arrival). Empty: silent.
@export var sfx_open: AudioStream
## Heard as it closes.
@export var sfx_close: AudioStream
## Seconds after the closing starts that its sound plays: 0 at once (a drawer), the time the leaf takes
## to swing shut for a door that slams.
@export_range(0.0, 3.0, 0.05) var sfx_close_delay_s: float = 0.0
## Loudness (dB) of those sounds at 2 m.
@export_range(-40.0, 12.0, 0.5) var sfx_db: float = -6.0

var _leaf: Node3D
var _rest: Transform3D
var _latch: Node3D
var _latch_rest: Transform3D
## How far open it is shown: 0 shut, 1 open.
var _open: float = 0.0
var _tween: Tween


func _ready() -> void:
	super()
	_leaf = get_node_or_null(leaf_path) as Node3D
	if _leaf != null:
		_rest = _leaf.transform
	_latch = get_node_or_null(latch_path) as Node3D if not latch_path.is_empty() else null
	if _latch != null:
		_latch_rest = _latch.transform
	# The building's state can be shown before the part is in the tree (the state arrives before the
	# building is placed): the leaf was not known then, so it takes that state now.
	if _leaf != null and is_on:
		_set_open(1.0)


func _play(stream: AudioStream) -> void:
	Sfx3D.play_pitched(_leaf, stream, sfx_db, 2.0, 15.0, Sfx3D.Attenuation.VERY_SHORT, randf_range(0.95, 1.05))


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
	if not GameOrchestrator.is_server():
		if on or sfx_close_delay_s <= 0.0:
			_play(sfx_open if on else sfx_close)
		else:
			get_tree().create_timer(sfx_close_delay_s).timeout.connect(func() -> void:
				if is_instance_valid(self) and not is_on:  # reopened meanwhile: no slam
					_play(sfx_close))
	_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(_set_open, _open, target, duration_s * absf(target - _open))


## How far the latch ([0]) and the leaf ([1]) are at [param t] of the motion, the latch first over
## [param share] of it. Pure, for the tests.
static func phases(t: float, share: float) -> Vector2:
	if share <= 0.0:
		return Vector2(t, t)
	return Vector2(clampf(t / share, 0.0, 1.0), clampf((t - share) / (1.0 - share), 0.0, 1.0))


func _set_open(t: float) -> void:
	_open = t
	var share: float = latch_share if _latch != null else 0.0
	var at: Vector2 = phases(t, share)
	if _latch != null:
		_latch.transform = pose(_latch_rest, latch_axis, latch_angle_deg, Vector3.ZERO, at.x)
	_leaf.transform = pose(_rest, hinge_axis, open_angle_deg, open_slide, at.y)
