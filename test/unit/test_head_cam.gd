extends GutTest
## HeadCam: the first-person camera holds each posture's eye point, taken once from the head standing
## still; moving, it follows the forward lean and nothing else; it follows the head through a stance
## transition or a vault; idle breathing, turning on the spot and a 3D screen move nothing. Head
## positions are body-frame, from a rest at the origin.

const FORWARD : float = 0.12
const CROUCH_Y : float = -0.5

var _cam : HeadCam


func before_each() -> void:
	_cam = HeadCam.new()
	_cam.capture_rest(Vector3.ZERO, Vector3(0.0, 1.6, 0.0))


## One frame on foot in [param stance], with the head at [param head].
func _walk(head: Vector3, stance: int = 0) -> Vector3:
	return _cam.target(head, stance, false, true, false, false, FORWARD)


## One frame standing still in [param stance] (the posture's own pose).
func _idle(head: Vector3, stance: int = 0) -> Vector3:
	return _cam.target(head, stance, false, false, true, false, FORWARD)


func test_a_stride_does_not_move_the_view_up_down_or_sideways() -> void:
	var first : Vector3 = _walk(Vector3.ZERO)
	for i in 20:
		var t : Vector3 = _walk(Vector3(sin(i) * 0.03, absf(cos(i)) * 0.05, 0.0))
		assert_almost_eq(t.x, first.x, 0.0001, "no sway")
		assert_almost_eq(t.y, first.y, 0.0001, "no bounce")


func test_moving_the_forward_lean_is_followed_in_full() -> void:
	var upright : Vector3 = _walk(Vector3.ZERO)
	var leaning : Vector3 = _walk(Vector3(0.0, 0.0, -0.2))
	assert_almost_eq(leaning.z - upright.z, -0.2, 0.0001, "the eye leans with the torso, the neck stays behind")
	assert_almost_eq(upright.z, -FORWARD, 0.0001, "the eye at the front of the skull")


func test_breathing_standing_still_moves_nothing() -> void:
	var first : Vector3 = _idle(Vector3.ZERO)
	for i in 120:
		var breath := Vector3(0.0, sin(i * 0.1) * 0.02, cos(i * 0.1) * 0.015)
		assert_eq(_idle(breath), first, "frame %d" % i)


func test_turning_on_the_spot_moves_nothing() -> void:
	var first : Vector3 = _idle(Vector3.ZERO)
	# A turn clip swings the head: not moving, not still (the eye point is not retaken either).
	var turning : Vector3 = _cam.target(Vector3(0.04, 0.02, -0.06), 0, false, false, false, false, FORWARD)
	assert_eq(turning, first)


func test_a_stance_transition_is_followed_then_its_eye_held() -> void:
	# Crouching down: the transition clip lowers the head, and the view goes down with it.
	var during : Vector3 = _cam.target(Vector3(0.02, CROUCH_Y * 0.5, 0.0), 0, true, false, false, false, FORWARD)
	assert_almost_eq(during.y, 1.6 + CROUCH_Y * 0.5, 0.0001, "followed through the one-shot move")
	assert_almost_eq(during.x, 0.02, 0.0001)
	# The transition ends crouched: the first frame in the stance gives its eye...
	var crouched : Vector3 = _walk(Vector3(0.0, CROUCH_Y, 0.0), 1)
	assert_almost_eq(crouched.y, 1.6 + CROUCH_Y, 0.0001, "the crouch eye height")
	# ...and a crouched walk bobbing the head keeps it.
	var bobbing : Vector3 = _walk(Vector3(0.03, CROUCH_Y + 0.04, 0.0), 1)
	assert_almost_eq(bobbing.y, crouched.y, 0.0001, "held while moving")
	assert_almost_eq(bobbing.x, 0.0, 0.0001)


func test_the_eye_point_is_retaken_once_standing_still_then_never() -> void:
	_walk(Vector3(0.0, CROUCH_Y, 0.0), 1)  # first seen moving: provisional
	var settled : float = _idle(Vector3(0.0, CROUCH_Y + 0.1, 0.0), 1).y
	assert_almost_eq(settled, 1.6 + CROUCH_Y + 0.1, 0.0001, "taken from the still pose")
	assert_almost_eq(_idle(Vector3(0.0, CROUCH_Y + 0.13, 0.0), 1).y, settled, 0.0001, "a breath later: unchanged")


func test_at_a_screen_the_view_holds_still() -> void:
	var still : Vector3 = _idle(Vector3.ZERO)
	var reading : Vector3 = _cam.target(Vector3(0.02, 0.03, -0.1), 0, false, true, false, true, FORWARD)
	assert_eq(reading, still, "no lean, no sway, even walking at the console")


func test_the_rest_is_taken_once() -> void:
	_cam.capture_rest(Vector3(5.0, 5.0, 5.0), Vector3(9.0, 9.0, 9.0))
	assert_eq(_cam.camera_base, Vector3(0.0, 1.6, 0.0), "the first capture stands")
