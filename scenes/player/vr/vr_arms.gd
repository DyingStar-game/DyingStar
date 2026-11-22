class_name VrArms
extends Node
## The avatar's arms and hands follow the player's own, in VR: each wrist goes where the hand is, the
## elbow bent down and out, the hand turned like the real one and its fingers closed like them. The
## owner sees them looking down; the others will once the hands are sent to the server (phase 6).
##
## Where a hand is, best first:
## - the runtime's hand tracking (XR_EXT_hand_tracking -- from the cameras, or from the controller held,
##   like the Steam Frame's or the Index's): the wrist joint and every finger joint, whose bends close the
##   avatar's fingers. Godot hands the joints over in ITS humanoid convention, not OpenXR's: +Y along the
##   bone to the fingers, -Z out of the back of the hand (OpenXRHandTrackingExtension's bone adjustment);
##   read as OpenXR's (-Z fingers, +Y back), both hands came out turned a quarter outwards (2026-11-22);
## - else the controller's grip pose, whose axes OpenXR fixes: -Z along the handle from the little finger
##   to the thumb, X square to the palm (the back of the hand: +X on the right hand, -X on the left), so
##   the fingers' knuckles lie along -Y from the wrist; the wrist a little behind the palm, the index
##   closed by the trigger and the other fingers by the grip.
## A hand the runtime sees by neither lets the animation have the arm back.
##
## Not Godot's XRHandModifier3D: it copies each joint's turn onto the bone of the same name, which needs a
## hand whose bones have OpenXR's axes -- this retargeted rig's point anywhere. Here the hand is turned from
## the rest positions of its bones (wrist, knuckles), and the fingers are closed from straight
## (HumanoidHand.curl), whatever their axes.
##
## Everything is worked in the skeleton's space, multiplied up from local transforms (LocalFrame): the
## world is some 4e10 m out (see WristRaise). The arm is WristRaise's two-bone Reach, last of the
## skeleton's modifiers: it overrides the clip, the wrist raise and the screen poke; a driver's hands stay
## on the wheel (HandsOnWheel), and a load in the arms keeps the carrying pose.
##
## Built by VrRig for the owner's player, in VR only.

const SIDES: Array[String] = ["Left", "Right"]
## The runtime's hand trackers, left then right.
const HAND_TRACKERS: Array[StringName] = [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]
## Where the elbow points from the shoulder (m, the BODY's frame: +x right, +y up, -z forward), left
## then right: down, out to the side, a little back.
const POLES: Array[Vector3] = [Vector3(-0.3, -0.5, 0.25), Vector3(0.3, -0.5, 0.25)]
## From the controller's grip pose (the middle of the palm) back to the wrist (m).
const GRIP_TO_WRIST_M := 0.07
## How fast (1/s) an arm takes the hand, or gives it back to the animation.
const BLEND_RATE := 6.0
## With no hand tracking, each finger joint closes this far (deg) on a full pull of the trigger (index)
## or the grip (the others), knuckle out.
const PULL_CURL_DEG: Array[float] = [60.0, 75.0, 45.0]
## The first joint of each finger in XRHandTracker's order (metacarpal, proximal, intermediate, distal,
## tip follow): index, middle, ring, little -- HumanoidHand.FINGERS' order.
const FINGER_FIRST_JOINT: Array[int] = [6, 11, 16, 21]
## How far (deg) each finger joint may close, knuckle out: never back, never past a real hand's reach.
const FINGER_MAX_DEG: Array[float] = [90.0, 110.0, 80.0]
## How far (deg) the hand may bend from the forearm's line: past it, the hand stops at the limit.
const WRIST_MAX_DEG := 70.0
## The share of the hand's roll (about the forearm) the forearm takes: a forearm turns along with the
## hand, a wrist alone does not (left at the clip's, the wrist twisted like a wrung towel).
const FOREARM_TWIST := 0.6

var _rig: VrRig = null
var _player: Node3D = null
var _skeleton: Skeleton3D = null
var _arms: Array[Dictionary] = []  # per side: ik (WristRaise.Reach), hand (VrHand), upper, weight


## Put [param player]'s arms (a Player) on [param rig]'s hands.
func setup(rig: VrRig, player: Node3D) -> void:
	_rig = rig
	_player = player


func _process(delta: float) -> void:
	if _skeleton == null and not _attach():
		return
	if not is_instance_valid(_skeleton):
		_skeleton = null
		_arms.clear()
		return
	var player_from_skeleton: Transform3D = LocalFrame.of(_skeleton, _player)
	var skeleton_from_player: Transform3D = player_from_skeleton.affine_inverse()
	var skeleton_from_origin: Transform3D = skeleton_from_player * LocalFrame.of(_rig, _player)
	for side in _arms.size():
		var source: Dictionary = {} if not _arm_free(side) else hand_source(side)
		_drive(side, source, delta, skeleton_from_origin, skeleton_from_player)


## Where hand [param side] (0 left, 1 right) is, in the rig's (the XR origin's) space: {"wrist": its
## place, "forward": from the wrist to the knuckles, "dorsal": out of the back of the hand, "curls": per
## finger of HumanoidHand.FINGERS, its three joints' bends (deg)}. Empty when the runtime sees it by no
## means.
func hand_source(side: int) -> Dictionary:
	var tracker := XRServer.get_tracker(HAND_TRACKERS[side]) as XRHandTracker
	if tracker != null and tracker.has_tracking_data:
		var wrist_flags: int = tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST)
		var needed: int = XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID
		if wrist_flags & needed == needed:
			var joints: Array[Vector3] = []
			for joint in XRHandTracker.HAND_JOINT_MAX:
				joints.append(tracker.get_hand_joint_transform(joint).origin)
			var hand := tracked_hand(tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST))
			hand["curls"] = finger_curls(joints)
			return hand
	var controller: XRController3D = _rig.left_hand if side == 0 else _rig.right_hand
	if controller == null or not controller.get_has_tracking_data():
		return {}
	var hand := gripped_hand(controller.transform, side == 0)
	hand["curls"] = pull_curls(controller.get_float(&"trigger"), controller.get_float(&"squeeze"))
	return hand


## A hand from the hand tracker's wrist joint [param wrist] (Godot's humanoid convention: +Y to the
## fingers, -Z out of the back of the hand).
static func tracked_hand(wrist: Transform3D) -> Dictionary:
	return {"wrist": wrist.origin, "forward": wrist.basis.y.normalized(), "dorsal": -wrist.basis.z.normalized()}


## A hand from a controller's grip pose [param grip] held in the [param left] hand or the right one
## (OpenXR's grip: -Z along the handle, little finger to thumb; +X square to the palm, out of the back of
## the right hand and out of the palm of the left one): the knuckles along -Y, the wrist GRIP_TO_WRIST_M
## behind the palm.
static func gripped_hand(grip: Transform3D, left: bool) -> Dictionary:
	var forward: Vector3 = -grip.basis.y.normalized()
	var dorsal: Vector3 = grip.basis.x.normalized() * (-1.0 if left else 1.0)
	return {"wrist": grip.origin - forward * GRIP_TO_WRIST_M, "forward": forward, "dorsal": dorsal}


## The bends (deg) of each finger's three joints, from the tracked joints' positions [param joints]
## (XRHandTracker's order): the angle each bone turns from the one before it.
static func finger_curls(joints: Array[Vector3]) -> Array:
	var curls: Array = []
	for first: int in FINGER_FIRST_JOINT:
		var bends: Array[float] = []
		for j in 3:
			var before: Vector3 = joints[first + j + 1] - joints[first + j]
			var after: Vector3 = joints[first + j + 2] - joints[first + j + 1]
			var bend: float = 0.0
			if before.length_squared() > 1e-10 and after.length_squared() > 1e-10:
				bend = rad_to_deg(before.angle_to(after))
			bends.append(bend)
		curls.append(bends)
	return curls


## The bends (deg) of each finger from the controller's [param trigger] (the index) and [param squeeze]
## (the other three), 0..1 each.
static func pull_curls(trigger: float, squeeze: float) -> Array:
	var curls: Array = []
	for f in 4:
		var pull: float = clampf(trigger if f == 0 else squeeze, 0.0, 1.0)
		var bends: Array[float] = []
		for degrees: float in PULL_CURL_DEG:
			bends.append(degrees * pull)
		curls.append(bends)
	return curls


## Hand the arm the animation's or the player's: a driver's hands are on the wheel, a load is held by
## both, a body on a bed lies as it lies, and the left forearm reading the DataPad is the wrist raise's.
func _arm_free(side: int) -> bool:
	var sample: Dictionary = _player.get("locomotion_sample") if _player.get("locomotion_sample") is Dictionary else {}
	if bool(sample.get("seated", false)) and bool(sample.get("driver", false)):
		return false
	if _player.get("_owner_carrying") == true or is_instance_valid(_player.get("lying_on")):
		return false
	return not (side == 0 and _player.get("datapad_raised") == true)


func _drive(side: int, source: Dictionary, delta: float, skeleton_from_origin: Transform3D,
		skeleton_from_player: Transform3D) -> void:
	var arm: Dictionary = _arms[side]
	var ik: WristRaise.Reach = arm["ik"]
	var hand: VrHand = arm["hand"]
	var weight: float = move_toward(float(arm["weight"]), 0.0 if source.is_empty() else 1.0, delta * BLEND_RATE)
	arm["weight"] = weight
	var eased: float = smoothstep(0.0, 1.0, weight)
	for modifier: SkeletonModifier3D in [ik, hand]:
		modifier.active = eased > 0.0
		modifier.influence = eased
	if source.is_empty():
		return  # fading back to the animation: the last targets hold meanwhile
	ik.target = skeleton_from_origin * (source["wrist"] as Vector3)
	var shoulder: Vector3 = _skeleton.get_bone_global_pose(int(arm["upper"])).origin
	ik.pole = shoulder + skeleton_from_player.basis * POLES[side]
	hand.forward = (skeleton_from_origin.basis * (source["forward"] as Vector3)).normalized()
	hand.dorsal = (skeleton_from_origin.basis * (source["dorsal"] as Vector3)).normalized()
	hand.curls = source["curls"]


## Find the avatar's skeleton (CharacterAnimator sets it up after the rig is built) and hang the arms on
## it, after its own modifiers. False while there is none yet.
func _attach() -> bool:
	var puppet: Node = _player.get("puppet") as Node
	var animator: Node = puppet.get_node_or_null(^"CharacterAnimator") if puppet != null else null
	var skeleton: Skeleton3D = animator.call(&"posed_skeleton") if animator != null else null
	if skeleton == null:
		return false
	_arms = attach(skeleton)
	_skeleton = skeleton if not _arms.is_empty() else null
	return _skeleton != null


## The two arms' modifiers under [param skeleton], last (they run in tree order): per side, its Reach then
## its VrHand. Empty when the rig lacks an arm or a hand.
static func attach(skeleton: Skeleton3D) -> Array[Dictionary]:
	var arms: Array[Dictionary] = []
	for side: String in SIDES:
		var upper: int = skeleton.find_bone(side + "UpperArm")
		var lower: int = skeleton.find_bone(side + "LowerArm")
		var hand_bone: int = skeleton.find_bone(side + "Hand")
		if upper == -1 or lower == -1 or hand_bone == -1:
			return []
		var ik := WristRaise.Reach.new()
		ik.name = "Vr%sArmIK" % side
		ik.upper = upper
		ik.lower = lower
		ik.hand = hand_bone
		ik.active = false
		skeleton.add_child(ik)
		var hand := VrHand.new()
		hand.name = "Vr%sHand" % side
		hand.setup(skeleton, side, hand_bone, lower)
		hand.active = false
		skeleton.add_child(hand)
		arms.append({"ik": ik, "hand": hand, "upper": upper, "weight": 0.0})
	return arms


## A hand turned like the player's ([member forward] to the fingers, [member dorsal] out of its back, in
## the skeleton's space) and its fingers closed by [member curls] (deg, per finger, per joint). Its own
## axes are read from the rest positions of the wrist and the knuckles, never from the bone's axes.
##
## Within a body's limits: the hand bends at most WRIST_MAX_DEG from the forearm, which takes
## FOREARM_TWIST of its roll; each finger closes about its OWN hinge (square to the finger and the palm)
## by no more than FINGER_MAX_DEG, never backwards. On one hinge for the whole hand (HandsOnWheel's), the
## ring and the little fingers, splayed from the hand's line, swung out sideways as they closed
## (playtest 2026-11-22).
class VrHand:
	extends SkeletonModifier3D
	var forward: Vector3 = Vector3.FORWARD
	var dorsal: Vector3 = Vector3.UP
	var curls: Array = []
	var _side: String = "Right"
	var _hand: int = -1
	var _lower: int = -1
	var _middle: int = -1
	var _index: int = -1
	var _little: int = -1
	var _chains: Array = []

	func setup(skeleton: Skeleton3D, side: String, hand: int, lower_arm: int) -> void:
		_side = side
		_hand = hand
		_lower = lower_arm
		_middle = skeleton.find_bone(side + "MiddleProximal")
		_index = skeleton.find_bone(side + "IndexProximal")
		_little = skeleton.find_bone(side + "LittleProximal")
		_chains = HumanoidHand.finger_chains(skeleton, side)

	func _process_modification_with_delta(_delta: float) -> void:
		var skeleton: Skeleton3D = get_skeleton()
		if skeleton == null or _hand == -1 or _middle == -1 or _index == -1 or _little == -1:
			return
		var rest: Transform3D = skeleton.get_bone_global_rest(_hand)
		var rest_forward: Vector3 = skeleton.get_bone_global_rest(_middle).origin - rest.origin
		var across: Vector3 = skeleton.get_bone_global_rest(_index).origin - skeleton.get_bone_global_rest(_little).origin
		var rest_dorsal: Vector3 = VrArms.back_of_hand(rest_forward, across, _side == "Left")
		var pose: Transform3D = skeleton.get_bone_global_pose(_hand)
		var fingers: Vector3 = forward
		var back: Vector3 = dorsal
		if _lower != -1:
			var lower: Transform3D = skeleton.get_bone_global_pose(_lower)
			var axis: Vector3 = (pose.origin - lower.origin).normalized()
			var limited: Array[Vector3] = VrArms.wrist_within(axis, fingers, back)
			fingers = limited[0]
			back = limited[1]
			var want: Basis = VrArms.turned_hand(rest.basis, rest_forward, rest_dorsal, fingers, back)
			var roll: float = VrArms.roll_about(want, pose.basis, axis)
			lower.basis = Basis(axis, roll * VrArms.FOREARM_TWIST) * lower.basis
			skeleton.set_bone_global_pose(_lower, lower)
		pose.basis = VrArms.turned_hand(rest.basis, rest_forward, rest_dorsal, fingers, back)
		skeleton.set_bone_global_pose(_hand, pose)
		if curls.size() != _chains.size():
			return
		var palm: Vector3 = -back
		for f in _chains.size():
			var chain: Array = _chains[f]
			if chain.is_empty() or chain[0] == -1:
				continue
			var knuckle: Transform3D = pose * skeleton.get_bone_rest(chain[0])
			var along: Vector3 = knuckle.origin - pose.origin
			if chain.size() > 1 and chain[1] != -1:
				along = (knuckle * skeleton.get_bone_rest(chain[1])).origin - knuckle.origin
			var hinge: Vector3 = along.cross(palm)
			if hinge.length_squared() < 1e-12:
				continue
			HumanoidHand.curl(skeleton, pose, [chain], [VrArms.within_limits(curls[f])], hinge.normalized())


## A finger's bends [param bends] (deg, knuckle out) kept to FINGER_MAX_DEG, and never backwards.
static func within_limits(bends: Array) -> Array:
	var kept: Array = []
	for j in bends.size():
		kept.append(clampf(float(bends[j]), 0.0, FINGER_MAX_DEG[mini(j, FINGER_MAX_DEG.size() - 1)]))
	return kept


## The hand's [param fingers] and [param back] directions turned back within WRIST_MAX_DEG of the forearm's
## line [param axis] (elbow to wrist): [fingers, back].
static func wrist_within(axis: Vector3, fingers: Vector3, back: Vector3) -> Array[Vector3]:
	var bend: float = fingers.angle_to(axis)
	var limit: float = deg_to_rad(WRIST_MAX_DEG)
	var hinge: Vector3 = fingers.cross(axis)
	if bend <= limit or hinge.length_squared() < 1e-12:
		return [fingers, back]
	var turn := Basis(hinge.normalized(), bend - limit)
	return [turn * fingers, turn * back]


## How far (rad, signed about [param axis]) the basis [param want] is turned from [param have] about that
## axis: the roll part of the turn between them.
static func roll_about(want: Basis, have: Basis, axis: Vector3) -> float:
	var turn: Quaternion = want.get_rotation_quaternion() * have.get_rotation_quaternion().inverse()
	var twist: Quaternion = HandsOnWheel.twist_about(turn, axis)
	if twist.w < 0.0:
		twist = -twist  # the short way round: an angle of 0..PI
	var angle: float = twist.get_angle()
	return -angle if Vector3(twist.x, twist.y, twist.z).dot(axis) < 0.0 else angle


## The direction out of the back of a hand whose fingers go [param forward] and whose knuckles run
## [param across] from the little finger to the index: forward x across for a right hand, the other way
## for a [param left] one (checked on a T-posed hand, palm down: up for both).
static func back_of_hand(forward: Vector3, across: Vector3, left: bool) -> Vector3:
	var back: Vector3 = across.cross(forward) if left else forward.cross(across)
	return back.normalized()


## The hand bone's basis (skeleton's space) whose rest [param rest] is turned so that its fingers, going
## [param rest_forward] at rest, go [param forward], and the back of it, [param rest_dorsal] at rest, faces
## [param dorsal]. The bone's scale is kept.
static func turned_hand(rest: Basis, rest_forward: Vector3, rest_dorsal: Vector3, forward: Vector3,
		dorsal: Vector3) -> Basis:
	return _frame(forward, dorsal) * _frame(rest_forward, rest_dorsal).inverse() * rest


## An orthonormal basis whose X is [param along] and whose Y is [param up], made square to it.
static func _frame(along: Vector3, up: Vector3) -> Basis:
	var x: Vector3 = along.normalized()
	var y: Vector3 = (up - x * up.dot(x)).normalized()
	return Basis(x, y, x.cross(y))
