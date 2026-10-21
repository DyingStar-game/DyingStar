class_name ScreenPoke
extends SkeletonModifier3D

## The right hand reaches out and taps a screen with its index where it was clicked, then comes back.
## Two modifiers, in this order under the skeleton: a TwoBoneIK3D brings the wrist a finger's length
## short of the point (shoulder -> elbow -> wrist, the elbow bent towards a pole below and outside the
## shoulder), then this one points the hand at the point and closes the other fingers into a fist, the
## index held straight. Both blend with one weight (0 = the clip alone), the tap's envelope.
##
## CharacterAnimator drives it from Player.tap_serial / tap_point, on the owner AND on every remote
## avatar: the tap is an EVENT, replicated as "tap:<n>:x:y:z" on the `action` field. Points are in the
## SKELETON's space, never worked out from world positions (see WristRaise.drive).

## Seconds the hand takes to reach the screen: the tap's sound plays then, on the contact.
const REACH_S := 0.16
## Seconds the finger rests on the screen.
const HOLD_S := 0.08
## Seconds the arm takes to come back down.
const BACK_S := 0.3
## How far (degrees) each joint of the middle, ring and little fingers closes, from straight: a fist,
## the index out.
const FIST_DEG: Array[float] = [80.0, 95.0, 60.0]
## Where the elbow goes, from the shoulder, in the body's metres: out to the side, down, a little ahead.
const POLE_OFFSET := Vector3(0.25, -0.45, -0.1)

var _ik: TwoBoneIK3D = null
var _target: Node3D = null
var _pole: Node3D = null
var _upper: int = -1
var _hand: int = -1
var _fingers: Array = []
## The hand's own frame at rest, in its bone's space: wrist -> knuckles, and the palm's normal.
var _reach: Vector3 = Vector3.FORWARD
var _palm: Vector3 = Vector3.DOWN
## Wrist -> index tip, the finger straight (rig's space).
var _finger_length: float = 0.15
## The point tapped, skeleton's space (drive).
var _point: Vector3 = Vector3.ZERO


## Build the rig under [param skeleton] for its RIGHT arm, by the humanoid profile's bone names. Null
## when the arm lacks its upper arm, forearm or hand.
static func attach(skeleton: Skeleton3D) -> ScreenPoke:
	if skeleton == null:
		return null
	var upper: int = skeleton.find_bone("RightUpperArm")
	var lower: int = skeleton.find_bone("RightLowerArm")
	var hand: int = skeleton.find_bone("RightHand")
	if upper == -1 or lower == -1 or hand == -1:
		return null
	var ik := TwoBoneIK3D.new()
	ik.name = "PokeIK"
	skeleton.add_child(ik)
	ik.set_setting_count(1)
	ik.set_root_bone(0, upper)
	ik.set_middle_bone(0, lower)
	ik.set_end_bone(0, hand)
	var poke := ScreenPoke.new()
	poke.name = "PokeHand"
	skeleton.add_child(poke)
	poke._ik = ik
	poke._upper = upper
	poke._hand = hand
	poke._fingers = HumanoidHand.finger_chains(skeleton, "Right")
	poke._measure(skeleton)
	poke._target = HumanoidHand.marker(skeleton, "PokeTarget")
	poke._pole = HumanoidHand.marker(skeleton, "PokePole")
	ik.set_target_node(0, ik.get_path_to(poke._target))
	ik.set_pole_node(0, ik.get_path_to(poke._pole))
	poke.drive(0.0, Vector3.ZERO, Vector3.ZERO)
	return poke


## How far the tap has gone [param t] seconds after the click: 0 (the clip alone) .. 1 (the finger on
## the screen), up in REACH_S, held HOLD_S, down in BACK_S. Pure, for the tests.
static func envelope(t: float) -> float:
	if t <= 0.0 or t >= REACH_S + HOLD_S + BACK_S:
		return 0.0
	if t < REACH_S:
		return t / REACH_S
	if t < REACH_S + HOLD_S:
		return 1.0
	return 1.0 - (t - REACH_S - HOLD_S) / BACK_S


## The `action` event of the [param n]-th tap at [param point] (the body's frame): "tap:<n>:x:y:z". The
## counter makes every tap a new value, which the delta compression would otherwise drop.
static func tap_action(n: int, point: Vector3) -> String:
	return "tap:%d:%.3f:%.3f:%.3f" % [n, point.x, point.y, point.z]


## The point of a "tap:<n>:x:y:z" event, or null when [param action] is not a tap.
static func parse_tap(action: String) -> Variant:
	var parts: PackedStringArray = action.split(":")
	if parts.size() != 5 or parts[0] != "tap":
		return null
	return Vector3(parts[2].to_float(), parts[3].to_float(), parts[4].to_float())


## Where the wrist goes to put the index tip, [param finger] long, on [param point], reaching from
## [param shoulder]: short of the point along the line from the shoulder. Pure, for the tests.
static func wrist_for(shoulder: Vector3, point: Vector3, finger: float) -> Vector3:
	var along: Vector3 = point - shoulder
	if along.length() <= finger:
		return shoulder
	return point - along.normalized() * finger  # out of reach: the IK holds the arm straight towards it


## Once a frame, before the skeleton is posed: blend in by [param weight] (0..1, eased here), the index
## on [param point], the elbow towards [param pole] -- both in the SKELETON's space.
func drive(weight: float, point: Vector3, pole: Vector3) -> void:
	var w: float = smoothstep(0.0, 1.0, weight)
	active = w > 0.0
	_ik.active = active
	influence = w
	_ik.influence = w
	if not active:
		return
	_point = point
	_target.position = wrist_for(shoulder(), point, _finger_length)
	_pole.position = pole


## The shoulder the arm reaches from, skeleton's space, as the clip has it now.
func shoulder() -> Vector3:
	var skeleton: Skeleton3D = get_skeleton()
	return skeleton.get_bone_global_pose(_upper).origin if skeleton != null else Vector3.ZERO


## After the IK: the hand pointed at the point, the index straight, the other fingers in a fist.
func _process_modification_with_delta(_delta: float) -> void:
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null:
		return
	var parent: int = skeleton.get_bone_parent(_hand)
	var forearm: Transform3D = skeleton.get_bone_global_pose(parent)
	var was: Transform3D = forearm * skeleton.get_bone_pose(_hand)
	var reach: Vector3 = _point - was.origin
	if reach.length() < 1e-5:
		return
	reach = reach.normalized()
	var palm: Vector3 = was.basis.orthonormalized() * _palm  # keep the palm's side, square to the new reach
	palm = palm - reach * palm.dot(reach)
	if palm.length() < 1e-5:
		return
	palm = palm.normalized()
	var rest_frame := Basis(_reach, _palm, _reach.cross(_palm))
	var hold: Basis = Basis(reach, palm, reach.cross(palm)) * rest_frame.inverse()
	var hand := Transform3D(hold * Basis.from_scale(was.basis.get_scale()), was.origin)
	skeleton.set_bone_pose_rotation(_hand, (forearm.basis.inverse() * hand.basis).get_rotation_quaternion())
	var straight: Array[float] = [0.0, 0.0, 0.0]
	HumanoidHand.curl(skeleton, hand, _fingers, [straight, FIST_DEG, FIST_DEG, FIST_DEG],
			reach.cross(palm).normalized())


## The hand's frame at rest (as HandsOnWheel measures it) and the index's length, wrist to tip.
func _measure(skeleton: Skeleton3D) -> void:
	var rest: Transform3D = skeleton.get_bone_global_rest(_hand)
	var index: Array = _fingers[0]
	var middle: int = _fingers[1][0]
	var little: int = _fingers[3][0]
	if index[0] == -1 or middle == -1 or little == -1:
		return
	var reach: Vector3 = skeleton.get_bone_global_rest(middle).origin - rest.origin
	var across: Vector3 = skeleton.get_bone_global_rest(index[0]).origin - skeleton.get_bone_global_rest(little).origin
	var to_bone: Basis = rest.basis.orthonormalized().inverse()
	_reach = (to_bone * reach).normalized()
	_palm = (to_bone * HandsOnWheel.palm_normal(reach, across, false)).normalized()
	var joints: Array[Vector3] = [rest.origin]
	for bone: int in index:
		if bone != -1:
			joints.append(skeleton.get_bone_global_rest(bone).origin)
	var length: float = 0.0
	for i in range(1, joints.size()):
		length += joints[i].distance_to(joints[i - 1])
	# The last joint is the distal bone's root: its tip is about one more phalanx out.
	_finger_length = length + joints[-1].distance_to(joints[-2]) if joints.size() > 2 else length
