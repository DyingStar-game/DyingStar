class_name HandsOnWheel
extends SkeletonModifier3D
## Puts a driver's hands on the steering wheel, in three modifiers under the skeleton, in this order:
## - Lean works out, from the clip's pose of this frame, where each wrist and elbow must go, and bends the
##   spine towards the wheel just enough for both wrists to come within a comfortable reach: an arm whose
##   target is out of reach is held straight, and no elbow can bend (playtest 2026-10-16: arms stiff and
##   level, where a driver's elbows hang low);
## - a TwoBoneIK3D with a setting per arm brings each wrist there (shoulder -> elbow -> wrist, the elbow
##   bent towards a pole below the shoulder, close to the body);
## - this one then turns each hand so that it holds the rim -- in line with the forearm, palm towards the
##   wheel's centre -- gives the hand's roll to the forearm, and closes the four fingers round the rim.
## The grips are the two points the vehicle hangs on its wheel (Vehicle.steering_grips), which turn with
## it. All blend with one weight, 0 = the Driving clip alone. CharacterAnimator builds it and drives it on
## every avatar of a client, the owner's and the others': it reads only who is seated where.
##
## Everything is worked out INSIDE the modifiers, from the pose the clip gives this frame. Worked out in
## _process, it read the shoulders sometimes before and sometimes after the last frame's lean, so the
## targets and the lean chased each other and the driver bobbed (playtest 2026-10-16).
## Every point is in the SKELETON's space, from transforms multiplied up to a common ancestor (the vehicle
## the driver is a child of), never from world positions: the world is some 4e10 m out, and going through
## two global transforms made an IK target shake by micrometres a frame, which an arm multiplies (measured
## on the DataPad arm, 2026-10-15).

## Where the elbows go, from the shoulder, in metres of the rig's space: x out to the shoulder's side, y
## down, z towards the wheel. A driver's elbows hang low, under the shoulders, close to the body.
const POLE_OFFSET := Vector3(0.1, -0.7, -0.05)
## The share of an arm's full length (shoulder to wrist, straight) a driver holds the wheel at: the
## elbow stays bent.
const COMFORT_REACH := 0.85
## Furthest (radians) the spine leans towards the wheel to bring it within reach.
const MAX_LEAN := deg_to_rad(25.0)
## How fast (1/s) the lean follows what the reach needs: the clip breathes, the spine must not twitch.
const LEAN_RATE := 6.0
## Fallback wrist-to-knuckles length (m), for a rig with no finger bone to measure it from.
const KNUCKLES_M := 0.09
## How far (m) the hand sits out from the rim's centre line: the rim lies in the palm, not in the bones.
const RIM_GAP_M := 0.02
## The fingers lean this far (radians) from straight ahead towards the wheel's centre: over the rim.
const REACH_TILT := 0.2
## How much of the hand's line follows the forearm rather than the wheel's face: a wrist nearly in line
## with the forearm, not bent to point the fingers straight ahead.
const ARM_FOLLOW := 0.85
## Rounds of "where the forearm runs -> where the hand holds -> where the wrist goes": the wrist moves the
## elbow, which turns the forearm. Three settle it to well under a millimetre.
const FIT_ROUNDS := 3
## How far (degrees) each finger joint closes round the rim, from the knuckle out, counted from the
## fingers held STRAIGHT (the rig's rest): added to the clip's own curl, they closed through the palm.
## The thumb is left as the clip has it, along the rim (HumanoidHand.FINGERS).
const CURL_DEG: Array[float] = [45.0, 55.0, 30.0]

var _ik: TwoBoneIK3D = null
## How far (0..1) the LEFT hand has been taken off the wheel -- the wrist raised to read the DataPad. Past
## half way it is no longer turned to hold the rim nor closed round it: the wrist raise, which runs after
## this rig, has the arm, and a fist held before the eyes read as a hand still gripping nothing.
var left_released: float = 0.0
var _lean: Lean = null
var _arms: Array[Arm] = []
var _grips: Array = []  # the two grips, either order, skeleton's space (drive)
var _hub: Vector3 = Vector3.ZERO  # the rim's centre, skeleton's space (drive)


## One arm of the rig: its bones, its markers, the hand's own frame measured at rest, and this frame's
## wanted hold.
class Arm:
	var upper: int = -1
	var lower: int = -1
	var hand: int = -1
	var fingers: Array = []  # one Array[int] per finger: its joints, knuckle out (-1 where missing)
	var target: Node3D = null  # the wrist's place (the IK's target)
	var pole: Node3D = null
	var reach: Vector3 = Vector3.FORWARD  # the hand's frame: wrist -> knuckles, in the hand bone's space
	var palm: Vector3 = Vector3.DOWN  # the palm's normal, in the hand bone's space
	var knuckles: float = KNUCKLES_M  # wrist -> knuckles, in the rig's space
	var upper_length: float = 0.0  # shoulder -> elbow, in the rig's space
	var lower_length: float = 0.0  # elbow -> wrist, in the rig's space
	var length: float = 0.0  # shoulder -> wrist, arm straight, in the rig's space
	var want_reach: Vector3 = Vector3.FORWARD  # this frame: where the fingers should point, skeleton's space
	var want_palm: Vector3 = Vector3.DOWN  # this frame: where the palm should face, skeleton's space


## Runs first: from the clip's pose of this frame, places the IK's targets and poles and leans the spine
## (see the class notes). Reads its data from the rig (HandsOnWheel.drive).
class Lean:
	extends SkeletonModifier3D
	var rig: HandsOnWheel = null
	var spine: int = -1
	var angle: float = 0.0  # the lean being held, smoothed (radians)

	func _process_modification_with_delta(delta: float) -> void:
		var skeleton: Skeleton3D = get_skeleton()
		if skeleton == null or rig == null or rig._grips.size() != 2:
			return
		var arms: Array[HandsOnWheel.Arm] = rig._arms
		var hub: Vector3 = rig._hub
		var shoulders: Array[Vector3] = [skeleton.get_bone_global_pose(arms[0].upper).origin,
				skeleton.get_bone_global_pose(arms[1].upper).origin]
		var held: Array = HandsOnWheel.by_side(rig._grips, shoulders[0].x, shoulders[1].x)
		var away: Vector3 = HandsOnWheel.away_from_driver(rig._grips, hub, (shoulders[0] + shoulders[1]) * 0.5)
		if spine != -1:
			var pose: Transform3D = skeleton.get_bone_global_pose(spine)
			var ahead: Vector3 = hub - pose.origin
			ahead.y = 0.0
			var axis: Vector3 = Vector3.UP.cross(ahead)
			if axis.length() > 1e-6:
				axis = axis.normalized()
				var wrists: Array = []
				var reaches: Array = []
				for i in 2:
					wrists.append(rig._wrist_for(i, held[i], hub, away, (held[i] - shoulders[i]).normalized()))
					reaches.append(arms[i].length * HandsOnWheel.COMFORT_REACH)
				var found: Array = HandsOnWheel.lean_needed(pose.origin, axis, shoulders, wrists, reaches,
						HandsOnWheel.MAX_LEAN)
				angle = lerpf(angle, found[0], 1.0 - exp(-HandsOnWheel.LEAN_RATE * delta))
				var turn := Basis(axis, angle)
				var parent: int = skeleton.get_bone_parent(spine)
				var above: Basis = skeleton.get_bone_global_pose(parent).basis if parent != -1 else Basis.IDENTITY
				skeleton.set_bone_pose_rotation(spine, (above.inverse() * (turn * pose.basis)).get_rotation_quaternion())
				for i in 2:  # where the shoulders are now: the arms reach from there
					shoulders[i] = pose.origin + turn * (shoulders[i] - pose.origin)
		var unit: float = 1.0 / maxf(skeleton.global_basis.get_scale().x, 1e-6)
		for i in 2:
			var arm: HandsOnWheel.Arm = arms[i]
			# Out on the shoulder's own side (a humanoid rig is centred on x = 0), down, towards the wheel.
			var side: float = signf(shoulders[i].x) if shoulders[i].x != 0.0 else (1.0 if i == 0 else -1.0)
			var toward: Vector3 = Vector3(hub.x - shoulders[i].x, 0.0, hub.z - shoulders[i].z).normalized()
			arm.pole.position = shoulders[i] + (Vector3(HandsOnWheel.POLE_OFFSET.x * side,
					HandsOnWheel.POLE_OFFSET.y, 0.0) + toward * HandsOnWheel.POLE_OFFSET.z) * unit
			# The hand in line with the forearm the IK will build, and the rim in its palm: the elbow is
			# worked out here as the IK will place it (elbow_for), the hand laid along that forearm, the
			# wrist put where that hand holds the rim -- which moves the elbow, so again (FIT_ROUNDS).
			var wrist: Vector3 = rig._wrist_for(i, held[i], hub, away, (held[i] - shoulders[i]).normalized())
			for _round in HandsOnWheel.FIT_ROUNDS:
				var elbow: Vector3 = HandsOnWheel.elbow_for(shoulders[i], wrist, arm.pole.position,
						arm.upper_length, arm.lower_length)
				wrist = rig._wrist_for(i, held[i], hub, away, (wrist - elbow).normalized())
			arm.target.position = wrist


## Build the rig under [param skeleton], by the humanoid profile's bone names (LeftUpperArm,
## LeftIndexProximal...). Null when either arm lacks its upper arm, forearm or hand.
static func attach(skeleton: Skeleton3D) -> HandsOnWheel:
	if skeleton == null:
		return null
	var arms: Array[Arm] = []
	for side: String in ["Left", "Right"]:
		var arm := Arm.new()
		arm.upper = skeleton.find_bone(side + "UpperArm")
		arm.lower = skeleton.find_bone(side + "LowerArm")
		arm.hand = skeleton.find_bone(side + "Hand")
		if arm.upper == -1 or arm.lower == -1 or arm.hand == -1:
			return null
		arm.fingers = HumanoidHand.finger_chains(skeleton, side)
		_measure_hand(skeleton, arm, side == "Left")
		arm.upper_length = skeleton.get_bone_global_rest(arm.upper).origin.distance_to(
				skeleton.get_bone_global_rest(arm.lower).origin)
		arm.lower_length = skeleton.get_bone_global_rest(arm.lower).origin.distance_to(
				skeleton.get_bone_global_rest(arm.hand).origin)
		arm.length = arm.upper_length + arm.lower_length
		arms.append(arm)
	var rig := HandsOnWheel.new()
	rig.name = "HandsOnWheelGrip"
	rig._arms = arms
	var lean := Lean.new()
	lean.name = "HandsOnWheelLean"
	lean.rig = rig
	lean.spine = skeleton.find_bone("Spine")
	var ik := TwoBoneIK3D.new()
	ik.name = "HandsOnWheelIK"
	# Tree order is the order modifiers run in: targets and lean, then the IK, then the hands.
	skeleton.add_child(lean)
	skeleton.add_child(ik)
	skeleton.add_child(rig)
	rig._ik = ik
	rig._lean = lean
	ik.set_setting_count(2)
	for i in 2:
		var arm: Arm = arms[i]
		ik.set_root_bone(i, arm.upper)
		ik.set_middle_bone(i, arm.lower)
		ik.set_end_bone(i, arm.hand)
		arm.target = HumanoidHand.marker(skeleton, "WheelWrist%d" % i)
		arm.pole = HumanoidHand.marker(skeleton, "WheelElbow%d" % i)
		ik.set_target_node(i, ik.get_path_to(arm.target))
		ik.set_pole_node(i, ik.get_path_to(arm.pole))
	rig.drive(0.0, [], Vector3.ZERO)
	return rig


## The hand's own frame at rest, in its bone's space: wrist -> middle knuckle, and the palm's normal from
## the knuckles' line (index -> little finger). Which way the palm faces follows from which hand it is --
## a left and a right hand are mirror images -- not from where the rig happens to face.
static func _measure_hand(skeleton: Skeleton3D, arm: Arm, left: bool) -> void:
	var rest: Transform3D = skeleton.get_bone_global_rest(arm.hand)
	var middle: int = arm.fingers[1][0]
	var index: int = arm.fingers[0][0]
	var little: int = arm.fingers[3][0]
	if middle == -1 or index == -1 or little == -1:
		arm.knuckles = KNUCKLES_M / maxf(skeleton.global_basis.get_scale().x if skeleton.is_inside_tree() else 1.0, 1e-6)
		return
	var reach: Vector3 = skeleton.get_bone_global_rest(middle).origin - rest.origin
	var across: Vector3 = skeleton.get_bone_global_rest(index).origin - skeleton.get_bone_global_rest(little).origin
	arm.knuckles = reach.length()
	var palm: Vector3 = palm_normal(reach, across, left)
	var to_bone: Basis = rest.basis.orthonormalized().inverse()
	arm.reach = (to_bone * reach).normalized()
	arm.palm = (to_bone * palm).normalized()


## A hand's palm normal from its [param reach] (wrist -> knuckles) and [param across] (little knuckle ->
## index knuckle). Pure, for the tests.
static func palm_normal(reach: Vector3, across: Vector3, left: bool) -> Vector3:
	var n: Vector3 = reach.cross(across) if left else across.cross(reach)
	return n.normalized()


## How a hand holds the rim at [param grip] on a wheel centred on [param hub] whose face looks
## [param away] from the driver, the forearm running along [param forearm] (unit, towards the wrist):
## the fingers reach along the forearm (ARM_FOLLOW) and over the rim (away, leaning in by REACH_TILT),
## the palm faces the centre. Returns [reach, palm], unit and square to each other. Pure, for the tests.
static func hold_directions(grip: Vector3, hub: Vector3, away: Vector3, forearm: Vector3) -> Array[Vector3]:
	var inward: Vector3 = (hub - grip) - away * (hub - grip).dot(away)
	inward = inward.normalized() if inward.length() > 1e-6 else away.cross(Vector3.UP).normalized()
	var over: Vector3 = (away * cos(REACH_TILT) + inward * sin(REACH_TILT)).normalized()
	var reach: Vector3 = over.lerp(forearm, ARM_FOLLOW).normalized() if forearm.length() > 1e-6 else over
	var palm: Vector3 = (inward - reach * inward.dot(reach)).normalized()
	return [reach, palm]


## The wheel's face direction away from the driver: square to the rim through [param grips], on the far
## side from [param shoulders_mid]. Pure, for the tests.
static func away_from_driver(grips: Array, hub: Vector3, shoulders_mid: Vector3) -> Vector3:
	var n: Vector3 = (Vector3(grips[0]) - hub).cross(Vector3(grips[1]) - hub)
	if n.length() < 1e-9:
		return (hub - shoulders_mid).normalized()
	n = n.normalized()
	return n if n.dot(hub - shoulders_mid) > 0.0 else -n


## [param grips] (two points) in the order of the arms, given each arm's shoulder x: each hand takes the
## grip on its own side. Pure, for the tests.
static func by_side(grips: Array, first_shoulder_x: float, second_shoulder_x: float) -> Array:
	var grips_order: float = signf(float(grips[0].x) - float(grips[1].x))
	var arms_order: float = signf(first_shoulder_x - second_shoulder_x)
	return [grips[1], grips[0]] if grips_order * arms_order < 0.0 else grips


## The least lean (radians, about [param axis] through [param pivot], up to [param max_angle]) that brings
## every [param wrists] point within its [param reaches] of its [param shoulders] point; and how far the
## worst one still falls short at that lean (0 when all are in reach). Continuous (a bisection), so a clip
## that breathes moves it smoothly, never by steps. Pure, for the tests.
static func lean_needed(pivot: Vector3, axis: Vector3, shoulders: Array, wrists: Array, reaches: Array,
		max_angle: float) -> Array:
	var gap := func(angle: float) -> float:
		var turn := Basis(axis, angle)
		var worst := -INF
		for i in shoulders.size():
			var shoulder: Vector3 = pivot + turn * (Vector3(shoulders[i]) - pivot)
			worst = maxf(worst, shoulder.distance_to(wrists[i]) - float(reaches[i]))
		return worst
	if gap.call(0.0) <= 0.0:
		return [0.0, 0.0]
	var at_max: float = gap.call(max_angle)
	if at_max > 0.0:
		return [max_angle, at_max]
	var lo := 0.0
	var hi: float = max_angle
	for _k in 20:
		var mid: float = (lo + hi) * 0.5
		if gap.call(mid) > 0.0:
			lo = mid
		else:
			hi = mid
	return [hi, 0.0]


## Where a two-bone arm's elbow goes (the IK's own geometry): [param upper] from [param shoulder] and
## [param lower] from [param wrist], bent towards [param pole]; the arm straight when the wrist is out of
## reach. Pure, for the tests.
static func elbow_for(shoulder: Vector3, wrist: Vector3, pole: Vector3, upper: float, lower: float) -> Vector3:
	var span: Vector3 = wrist - shoulder
	var d: float = clampf(span.length(), 1e-6, upper + lower)
	var along: Vector3 = span.normalized() if span.length() > 1e-6 else Vector3.FORWARD
	var bend: Vector3 = (pole - shoulder) - along * (pole - shoulder).dot(along)
	bend = bend.normalized() if bend.length() > 1e-6 else along.cross(Vector3.RIGHT).normalized()
	var cos_a: float = clampf((upper * upper + d * d - lower * lower) / (2.0 * upper * d), -1.0, 1.0)
	return shoulder + along * upper * cos_a + bend * upper * sqrt(1.0 - cos_a * cos_a)


## Where arm [param i]'s wrist goes to hold [param grip], its forearm running along [param forearm] (see
## hold_directions): back from the grip along the hand, and out from the rim by the palm's thickness.
## Also keeps the hold for this frame's hand (_process_modification_with_delta).
func _wrist_for(i: int, grip: Vector3, hub: Vector3, away: Vector3, forearm: Vector3) -> Vector3:
	var arm: Arm = _arms[i]
	var hold: Array[Vector3] = hold_directions(grip, hub, away, forearm)
	arm.want_reach = hold[0]
	arm.want_palm = hold[1]
	var skeleton: Skeleton3D = get_skeleton()
	var unit: float = 1.0 / maxf(skeleton.global_basis.get_scale().x, 1e-6) if skeleton != null else 1.0
	return grip - hold[0] * arm.knuckles * 0.85 - hold[1] * RIM_GAP_M * unit


## Once a frame: blend in by [param weight] (0..1, eased here), the hands on [param grips] -- two points,
## either order (by_side) -- of a wheel centred on [param hub], all in the SKELETON's space. Only stores
## them: the modifiers work everything out from the pose of the frame. Off (zero cost) at weight 0 or
## without both grips.
func drive(weight: float, grips: Array, hub: Vector3) -> void:
	var w: float = smoothstep(0.0, 1.0, weight) if grips.size() == 2 else 0.0
	active = w > 0.0
	_ik.active = active
	_lean.active = active
	influence = w
	_ik.influence = w
	_lean.influence = w
	_grips = grips
	_hub = hub
	if not active:
		_lean.angle = 0.0


## After the IK: each hand turned to hold the rim, then its fingers closed round it. Worked out from the
## LOCAL poses down each chain (forearm, hand, then knuckle to tip), so a joint's turn carries the ones
## after it. The hand takes exactly the hold its wrist was placed for (Lean, _wrist_for), so the rim lies
## in the palm: turned another way after the IK -- towards the forearm it built -- the hand swung off the
## rim (playtest 2026-10-16). Its roll about the forearm is given to the FOREARM, which is what turns a
## palm in a real arm: left at the wrist, it broke the wrist sideways (same playtest).
func _process_modification_with_delta(_delta: float) -> void:
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null:
		return
	for i: int in _arms.size():
		var arm: Arm = _arms[i]
		if i == 0 and left_released > 0.5:
			continue  # the left hand is off the wheel (see left_released)
		var forearm: Transform3D = skeleton.get_bone_global_pose(arm.lower)
		var hand_pose: Transform3D = skeleton.get_bone_pose(arm.hand)
		var was: Transform3D = forearm * hand_pose
		var reach: Vector3 = arm.want_reach
		var palm: Vector3 = arm.want_palm  # square to the reach already (hold_directions)
		var rest_frame := Basis(arm.reach, arm.palm, arm.reach.cross(arm.palm))
		var hold: Basis = Basis(reach, palm, reach.cross(palm)) * rest_frame.inverse()
		var hand := Transform3D(hold * Basis.from_scale(was.basis.get_scale()), was.origin)
		# The forearm turns about its own axis (elbow -> wrist, which stays put) by the hand's roll.
		var turn: Quaternion = (forearm.basis.orthonormalized().inverse() * hand.basis.orthonormalized()) \
				.get_rotation_quaternion()
		var roll: Quaternion = twist_about(turn, hand_pose.origin.normalized())
		var upper: Basis = skeleton.get_bone_global_pose(arm.upper).basis
		forearm.basis = forearm.basis * Basis(roll)
		skeleton.set_bone_pose_rotation(arm.lower, (upper.inverse() * forearm.basis).get_rotation_quaternion())
		skeleton.set_bone_pose_rotation(arm.hand, (forearm.basis.inverse() * hand.basis).get_rotation_quaternion())
		var curl_axis: Vector3 = reach.cross(palm).normalized()  # turning the reach to the palm closes the hand
		HumanoidHand.curl(skeleton, hand, arm.fingers, [CURL_DEG, CURL_DEG, CURL_DEG, CURL_DEG], curl_axis)


## The part of [param turn] that spins about [param axis] (unit): the "twist" of a swing-twist split.
## Pure, for the tests.
static func twist_about(turn: Quaternion, axis: Vector3) -> Quaternion:
	var along: Vector3 = axis * Vector3(turn.x, turn.y, turn.z).dot(axis)
	var twist := Quaternion(along.x, along.y, along.z, turn.w)
	return twist.normalized() if twist.length_squared() > 1e-12 else Quaternion.IDENTITY

