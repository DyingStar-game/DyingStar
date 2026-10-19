class_name HeadCam
extends RefCounted
## Where the first-person camera sits, from the head bone: the posture's eye, never the stride.
##
## The camera used to take the head bone's whole movement, scaled by a "bob" amount. The team wanted
## the bob gone everywhere, but that one movement also carried what the view must keep: going down when
## you crouch or lie prone, up as you climb over a ledge, forward as the torso leans into a sprint (or
## you look at your own neck). So the movement is split by what it is, not damped:
##   - A ONE-SHOT move (a stance transition, a vault) is followed in full: the view goes where the head
##     goes.
##   - Otherwise the camera holds the posture's EYE: a fixed point per stance, taken once from the head
##     standing still in that stance. Idle breathing, turning on the spot, an emote: nothing moves it.
##   - Moving, the FORWARD lean (z) is still followed in full — a sprint leans the torso far enough to
##     show the neck otherwise. Up / down and sideways never are: that is the bob.
## No clip-by-clip tuning: a new animation set brings its own eye points.

## The camera pivot's rest position (body frame, captured once): the anchor every target is built on.
var camera_base : Vector3 = Vector3.ZERO
## The head bone's position (body frame) at rest, standing still: the origin of every head offset.
var head_rest : Vector3 = Vector3.ZERO
var rest_captured : bool = false
## camera_base is taken, by capture_base or capture_rest: never retaken (see capture_base).
var _base_captured : bool = false
## Stance (0 standing, 1 crouched, 2 prone) -> its eye point (y, z) relative to the standing rest.
var _eye : Dictionary = {0: Vector2.ZERO}
## Stances whose eye point was taken standing still: final, never retaken (a breath would move it).
var _settled : Dictionary = {0: true}


## Take the camera's rest position, once: where the scene put the pivot. Seated or floating the pivot
## is then written as camera_base + an eye height, so taking it again every frame (as the animator did
## while the on-foot rest had never been captured) climbed the view by that height each frame: a player
## who reconnected in EVA, never on foot since, saw the camera rise kilometres over a body still
## answering the keys (2026-10-12).
func capture_base(camera_now: Vector3) -> void:
	if _base_captured:
		return
	camera_base = camera_now
	_base_captured = true


## Take the rest pose, once: the camera where the scene put it (unless capture_base already has), the
## head where the first frame has it.
func capture_rest(head_now: Vector3, camera_now: Vector3) -> void:
	if rest_captured:
		return
	head_rest = head_now
	capture_base(camera_now)
	rest_captured = true


## The camera's target (body frame) for a head at [param head_now] (body frame).
## [param stance]: the stance currently shown. [param follows_head]: a one-shot move is playing (stance
## transition, vault). [param moving]: walking, running or crawling. [param still]: standing still in
## the stance with nothing playing over it — the moment its eye point is taken. [param at_screen]:
## reading a 3D screen, the view holds still. [param forward]: how far the eye sits in front of the head
## bone (m).
func target(head_now: Vector3, stance: int, follows_head: bool, moving: bool, still: bool, at_screen: bool,
		forward: float) -> Vector3:
	var offset : Vector3 = head_now - head_rest
	var eye : Vector3
	if follows_head:
		eye = offset
	else:
		var point : Vector2 = _eye_point(stance, offset, still)
		# Moving: the lean in full -- the stride moves it under 3 cm, the gait ~24 cm, and the animator
		# eases the camera to it (head_cam_lean_smooth). Not moving, nothing leans.
		var lean : float = offset.z if moving and not at_screen else point.y
		eye = Vector3(0.0, point.x, lean)
	return camera_base + eye + Vector3(0.0, 0.0, -forward)


## The eye point (y, z) of [param stance]. Taken from the head the first frame the stance is seen (the
## end of the transition into it), then once more, for good, the first time it is held [param still].
func _eye_point(stance: int, offset: Vector3, still: bool) -> Vector2:
	if not _settled.get(stance, false) and (still or not _eye.has(stance)):
		_eye[stance] = Vector2(offset.y, offset.z)
		_settled[stance] = still
	return _eye[stance]
