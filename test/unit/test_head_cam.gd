extends GutTest
## HeadCam: the first-person camera takes the posture's eye height and the forward lean from the head,
## never the stride's bob; it follows the head through a stance transition or a vault, and holds still
## at a 3D screen. Head positions are body-frame, from a rest at the origin.

const DT : float = 1.0 / 60.0
const FORWARD : float = 0.12
const CROUCH_Y : float = -0.5

var _cam : HeadCam


func before_each() -> void:
	_cam = HeadCam.new()
	_cam.capture_rest(Vector3.ZERO, Vector3(0.0, 1.6, 0.0))


## One frame on foot, moving, in [param stance], with the head at [param head].
func _walk(head: Vector3, stance: int = 0) -> Vector3:
	return _cam.target(head, stance, false, false, false, FORWARD, DT)


func test_a_stride_does_not_move_the_view_up_down_or_sideways() -> void:
	var first : Vector3 = _walk(Vector3(0.0, 0.0, 0.0))
	for i in 20:
		var bob := Vector3(sin(i) * 0.03, absf(cos(i)) * 0.05, 0.0)
		var t : Vector3 = _walk(bob)
		assert_almost_eq(t.x, first.x, 0.0001, "no sway")
		assert_almost_eq(t.y, first.y, 0.0001, "no bounce")


func test_the_forward_lean_is_followed_in_full() -> void:
	var upright : Vector3 = _walk(Vector3.ZERO)
	var leaning : Vector3 = _walk(Vector3(0.0, 0.0, -0.2))
	assert_almost_eq(leaning.z - upright.z, -0.2, 0.0001, "the eye leans with the torso, the neck stays behind")
	assert_almost_eq(upright.z, -FORWARD, 0.0001, "the eye at the front of the skull")


func test_a_stance_transition_is_followed_then_its_height_held() -> void:
	# Crouching down: the transition clip lowers the head, and the view goes down with it.
	var during : Vector3 = _cam.target(Vector3(0.02, CROUCH_Y * 0.5, 0.0), 0, true, false, false, FORWARD, DT)
	assert_almost_eq(during.y, 1.6 + CROUCH_Y * 0.5, 0.0001, "followed through the one-shot move")
	assert_almost_eq(during.x, 0.02, 0.0001)
	# The transition ends crouched: the first frame in the stance takes its height...
	var crouched : Vector3 = _walk(Vector3(0.0, CROUCH_Y, 0.0), 1)
	assert_almost_eq(crouched.y, 1.6 + CROUCH_Y, 0.0001, "the crouch eye height")
	# ...and a crouched walk bobbing the head keeps it.
	var bobbing : Vector3 = _walk(Vector3(0.03, CROUCH_Y + 0.04, 0.0), 1)
	assert_almost_eq(bobbing.y, crouched.y, 0.0001, "held while moving")
	assert_almost_eq(bobbing.x, 0.0, 0.0001)


func test_standing_still_slowly_learns_the_eye_height() -> void:
	_walk(Vector3(0.0, CROUCH_Y, 0.0), 1)  # first seen: -0.5
	var y : float = 0.0
	for i in 600:  # ten seconds idle, the real idle pose a little higher
		y = _cam.target(Vector3(0.0, CROUCH_Y + 0.1, 0.0), 1, false, true, false, FORWARD, DT).y
	assert_almost_eq(y, 1.6 + CROUCH_Y + 0.1, 0.001, "converges on the idle pose")
	var one_breath : float = _cam.target(Vector3(0.0, CROUCH_Y + 0.12, 0.0), 1, false, true, false, FORWARD, DT).y
	assert_lt(absf(one_breath - y), 0.001, "a breath barely moves it")


func test_at_a_screen_the_view_holds_still() -> void:
	var t : Vector3 = _cam.target(Vector3(0.02, 0.03, -0.1), 0, false, true, true, FORWARD, DT)
	assert_almost_eq(t.x, 0.0, 0.0001)
	assert_almost_eq(t.z, -FORWARD, 0.0001, "no lean either")


func test_the_rest_is_taken_once() -> void:
	_cam.capture_rest(Vector3(5.0, 5.0, 5.0), Vector3(9.0, 9.0, 9.0))
	assert_eq(_cam.camera_base, Vector3(0.0, 1.6, 0.0), "the first capture stands")
