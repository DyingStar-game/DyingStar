class_name HeadCam
extends RefCounted
## Where the first-person camera sits, from the head bone: the posture's eye height, never the stride.
##
## The camera used to take the head bone's whole movement, scaled by a "bob" amount. The team wanted
## the bob gone everywhere, but that one movement also carried what the view must keep: going down when
## you crouch or lie prone, up as you climb over a ledge, forward as the torso leans into a sprint (or
## you look at your own neck). So the movement is split by what it is, not damped:
##   - FORWARD (z, the lean) is followed in full, always.
##   - Up / down and side to side (y, x) follow the head only through a ONE-SHOT move: a stance
##     transition or a vault. Walking, running, crawling, the camera holds the posture's eye height.
##   - That height is learned from the head itself, standing still in the posture (a slow average, so
##     idle breathing does not move it either), and first taken at the end of the transition into it.
## No clip-by-clip tuning: a new animation set brings its own heights.

## Standing still in a posture, how fast its eye height follows the head (per second): slow, so the
## breathing of an idle pose averages out instead of moving the view.
const LEARN_RATE : float = 1.5

## The camera pivot's rest position (body frame, captured once): the anchor every target is built on.
var camera_base : Vector3 = Vector3.ZERO
## The head bone's position (body frame) at rest, standing still: the origin of every head offset.
var head_rest : Vector3 = Vector3.ZERO
var rest_captured : bool = false
## Stance (0 standing, 1 crouched, 2 prone) -> eye height (m) above the standing rest, as learned.
var _eye_y : Dictionary = {0: 0.0}


## Take the rest pose, once: the camera where the scene put it, the head where an idle frame has it.
func capture_rest(head_now: Vector3, camera_now: Vector3) -> void:
	if rest_captured:
		return
	head_rest = head_now
	camera_base = camera_now
	rest_captured = true


## The camera's target (body frame) for a head at [param head_now] (body frame).
## [param stance]: the stance currently shown. [param follows_head]: a one-shot move is playing (stance
## transition, vault). [param idle]: standing still, nothing playing over the posture. [param at_screen]:
## reading a 3D screen — the view holds still. [param forward]: how far the eye sits in front of the head
## bone (m). [param delta]: the frame time, for the slow learning of the eye height.
func target(head_now: Vector3, stance: int, follows_head: bool, idle: bool, at_screen: bool,
		forward: float, delta: float) -> Vector3:
	var offset : Vector3 = head_now - head_rest
	var eye : Vector3
	if follows_head:
		eye = offset
	else:
		eye = Vector3(0.0, _eye_height(stance, offset.y, idle, delta), offset.z)
	if at_screen:
		# Reading a 3D screen: the view has to HOLD STILL. The lean drops too and the camera eases to the
		# posture's height through the same smoothing — a pointer on a list entry stays on it.
		eye = Vector3(0.0, _eye_y.get(stance, eye.y), 0.0)
	return camera_base + eye + Vector3(0.0, 0.0, -forward)


## Eye height of [param stance]: learned while [param idle], first taken from the head as it is when the
## stance has never been seen (the end of the transition into it), held otherwise.
func _eye_height(stance: int, head_y: float, idle: bool, delta: float) -> float:
	if not _eye_y.has(stance):
		_eye_y[stance] = head_y
	elif idle:
		_eye_y[stance] = lerpf(_eye_y[stance], head_y, 1.0 - exp(-LEARN_RATE * delta))
	return _eye_y[stance]
