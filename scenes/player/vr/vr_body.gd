class_name VrBody
extends Node
## The body under the head, in VR. The headset moves on its own -- the head turns, the player steps
## around the room -- while the game's body (the CharacterBody the server moves) only turns and walks
## when told. This keeps the two together, on foot, with nothing the server has to learn:
##
## - The body turns to where the head looks: at once while the stick walks (the stick's "forward" is
##   then the gaze -- or where the walking hand points, VR comfort's choice), and standing still only past
##   HEAD_FREE_YAW (look around freely, the body comes along when the head goes further). The rig turns
##   back by as much: the view does not move.
## - Room-scale: when the head has left the body by CHASE_START_M (the player stepped), the body walks
##   under it like with the stick (CHASE_* -- the server's walls hold it), and the rig slides back by
##   what the body moved: the view stays where the head is, only the body catches up. Not for a player
##   playing seated (VR comfort): leaning is not a step.
## - recenter(): the head over the body, facing its forward (at the first tracked frame in game, on the
##   runtime's own recenter, and on a long press of the right stick: VrInput).
##
## Seated, lying, weightless or with a menu open it stands aside. Built by VrRig, in VR only.

## Standing still, the head turns this far (rad) left or right before the body comes along.
const HEAD_FREE_YAW := deg_to_rad(50.0)
## The stick walks the player past this (0..1): the body then faces the gaze.
const STICK_WALKS := 0.2
## The body walks under the head once it is this far (m) from it, and stops within CHASE_STOP_M.
const CHASE_START_M := 0.25
const CHASE_STOP_M := 0.08
## How hard (0..1 of the stick, per m of gap) the body walks to catch up, at least CHASE_MIN: a push
## under the stick's deadzone (0.2) would not walk at all.
const CHASE_GAIN := 2.5
const CHASE_MIN := 0.35
## How long (s) after a catch-up the body's moves still slide the rig back: the server's answer to the
## last push arrives a round trip later.
const CHASE_TAIL_S := 0.5

## The stick as VrInput read it this frame (OpenXR convention: +y forward), before any catch-up.
var stick: Vector2 = Vector2.ZERO
## The push that walks the body under the head (stick convention), for VrInput to add to the stick.
var chase: Vector2 = Vector2.ZERO
## Is the player on foot, in gravity, playing (no menu)? A Callable for the tests.
var on_foot: Callable
## Is the player seated (in a vehicle)? A Callable for the tests.
var seated: Callable
## The comfort settings played (SettingsManager.vr unless a test hands its own).
var comfort: VrComfortSettings = null

var _rig: VrRig = null
var _player: Node3D = null
var _chasing: bool = false
var _tail: float = 0.0
var _last_position: Vector3 = Vector3.ZERO
var _last_parent: int = 0
var _was_seated: bool = false
var _recenter_pending: bool = true


func _init() -> void:
	on_foot = _on_foot
	seated = func() -> bool:
		var vehicle: Variant = _player.get("_seat_vehicle_uuid")
		return vehicle is String and vehicle != ""


## Keep [param player] (a Player) under [param rig]'s head.
func setup(rig: VrRig, player: Node3D) -> void:
	_rig = rig
	_player = player
	if comfort == null:
		comfort = SettingsManager.vr


func _ready() -> void:
	if XRMode.is_active():
		XRManager.recentered.connect(_on_runtime_recentered)


func _process(delta: float) -> void:
	if _rig == null or _player == null or not is_instance_valid(_rig.camera):
		return
	if _recenter_pending and _tracked():
		_recenter_pending = false
		recenter(on_foot.call())
	var sitting: bool = seated.call()
	if sitting and not _was_seated:
		recenter(false)  # sat down: the view straight ahead of the seat
	_was_seated = sitting
	var walking_here: bool = on_foot.call()
	var moved := _body_moved()
	if not walking_here:
		_chasing = false
		chase = Vector2.ZERO
		return
	var stick_walks: bool = stick.length() > STICK_WALKS
	var yaw: float = _rig.head_yaw()
	if stick_walks:
		turn_body(_walk_yaw(yaw))
	elif absf(yaw) > HEAD_FREE_YAW:
		turn_body(yaw - signf(yaw) * HEAD_FREE_YAW)
	# Room-scale: the body comes under the head; what it moves, the rig gives back.
	if (_chasing or _tail > 0.0) and not stick_walks:
		_rig.position -= Vector3(moved.x, 0.0, moved.z)
	_tail = maxf(_tail - delta, 0.0)
	var head := _rig.head_offset()
	var gap := Vector2(head.x, head.z)
	if stick_walks or (comfort != null and comfort.seated()):
		_chasing = false
	elif gap.length() > CHASE_START_M:
		_chasing = true
	elif gap.length() < CHASE_STOP_M:
		_chasing = false
	if _chasing:
		_tail = CHASE_TAIL_S
	chase = catch_up(gap) if _chasing else Vector2.ZERO


## Where the stick walks, as a yaw (rad) from the body's forward: the head's ([param head_yaw]), or the
## walking hand's when VR comfort says so and the runtime sees that hand.
func _walk_yaw(head_yaw: float) -> float:
	if comfort == null or not comfort.walk_by_hand():
		return head_yaw
	var hand: XRController3D = _rig.right_aim if comfort.left_handed() else _rig.left_aim
	if hand == null or not hand.get_has_tracking_data():
		return head_yaw
	return pointing_yaw(_rig.basis * hand.basis)


## The yaw (rad, left positive) of the direction [param along] points (its -Z), in its parent's frame.
static func pointing_yaw(along: Basis) -> float:
	var forward: Vector3 = along * Vector3.FORWARD
	return atan2(-forward.x, -forward.z)


## The stick push (OpenXR convention: +x right, +y forward) that walks the body towards a head [param gap]
## m away (x right, y back, the pivot's frame).
static func catch_up(gap: Vector2) -> Vector2:
	if gap.length() < 1e-4:
		return Vector2.ZERO
	return Vector2(gap.x, -gap.y).normalized() * clampf(gap.length() * CHASE_GAIN, CHASE_MIN, 1.0)


## Turn the body by [param angle] (rad, about its up, left positive), and the rig back by as much about
## the same axis: the head stays where it is, looking where it looked.
func turn_body(angle: float) -> void:
	if absf(angle) < 1e-5:
		return
	_player.rotate_object_local(Vector3.UP, angle)
	var pivot: Transform3D = (_rig.get_parent() as Node3D).transform
	_rig.transform = pivot.affine_inverse() * Transform3D(Basis(Vector3.UP, -angle), Vector3.ZERO) * pivot * _rig.transform


## The head over the body, looking along it: [param turn] the body to the head's yaw first (on foot), or
## turn the view to the body's forward (seated: the body is the seat's).
func recenter(turn: bool) -> void:
	var yaw: float = _rig.head_yaw()
	if turn:
		turn_body(yaw)
	else:
		_rig.transform = Transform3D(Basis(Vector3.UP, -yaw), Vector3.ZERO) * _rig.transform
	var head := _rig.head_offset()
	_rig.position -= Vector3(head.x, 0.0, head.z)
	_chasing = false
	chase = Vector2.ZERO


## The runtime recentred its own space (a long press of the headset's system button): the head is back at
## the origin of the tracking space, facing its forward -- the rig's own turn and slide no longer apply.
func _on_runtime_recentered() -> void:
	_rig.transform = Transform3D.IDENTITY
	_chasing = false
	_tail = 0.0


## How far the body moved since the last frame, in its own frame (m): its position is the parent's
## (a planet spins, a building, a truck), and a new parent is not a move.
func _body_moved() -> Vector3:
	var parent := _player.get_parent()
	var parent_id: int = parent.get_instance_id() if parent != null else 0
	var now: Vector3 = _player.position
	var moved := Vector3.ZERO
	if parent_id == _last_parent:
		moved = _player.basis.inverse() * (now - _last_position)
	_last_parent = parent_id
	_last_position = now
	return moved


## The headset gives a pose (no runtime in the tests: never).
func _tracked() -> bool:
	var xr := XRServer.primary_interface
	return xr != null and xr.is_initialized() and xr.get_tracking_status() == XRInterface.XR_NORMAL_TRACKING


func _on_foot() -> bool:
	if _player.get("active") != true or seated.call() or is_instance_valid(_player.get("lying_on")):
		return false
	var parents: Variant = _player.get("gravity_parents")
	return parents is Array and not parents.is_empty() and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
