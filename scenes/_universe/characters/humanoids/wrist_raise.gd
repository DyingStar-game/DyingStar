class_name WristRaise
extends SkeletonModifier3D

## Brings the left wrist up before the face, to read the DataPad worn on it. Two modifiers, in this
## order under the skeleton: a TwoBoneIK3D puts the wrist on a spot held in the BODY's frame (shoulder ->
## elbow -> wrist, the elbow bent towards a pole), then this one turns the forearm about its own axis
## until the screen faces the eye -- the IK places the wrist but leaves the forearm's twist wherever the
## animation had it, and a watch read edge-on is no watch.
##
## The spot is the body's, not the camera's: this rig's arms are short (0.24 m a bone), and a wrist held
## on the line of sight wherever one looks left the forearm pointing at the eye rather than across it
## (measured 2026-10-15: the screen faced the eye at 0.45 looking level). So the arm comes up to one
## reading pose (CharacterAnimator.datapad_wrist), and the EYES go to it (WristDatapad turns the owner's
## view; the replicated look shows it on others).
##
## Both blend with the same weight (0 = the animation alone, 1 = arm fully up), so the gesture is a
## fade between the clip and the raised pose. CharacterAnimator drives it from Player.datapad_raised, on
## the owner AND on every remote avatar.

var _ik: TwoBoneIK3D = null
var _target: Node3D = null
var _pole: Node3D = null
var _lower_arm: int = -1
var _hand: int = -1
## The screen's centre and its normal in the FOREARM bone's frame (see mount_transform).
var _screen_local: Vector3 = Vector3.ZERO
var _normal_local: Vector3 = Vector3.UP
## The eye the screen turns to, in the SKELETON's space (see drive).
var _eye_local: Vector3 = Vector3.ZERO


## Build the rig under `skeleton`: the IK, its target and pole, then the twist (tree order is the
## order modifiers run in). Null when the rig lacks one of the three arm bones.
static func attach(skeleton: Skeleton3D, upper_arm: int, lower_arm: int, hand: int) -> WristRaise:
	if skeleton == null or upper_arm == -1 or lower_arm == -1 or hand == -1:
		return null
	var ik := TwoBoneIK3D.new()
	ik.name = "WristIK"
	skeleton.add_child(ik)
	ik.set_setting_count(1)
	ik.set_root_bone(0, upper_arm)
	ik.set_middle_bone(0, lower_arm)
	ik.set_end_bone(0, hand)
	var raise := WristRaise.new()
	raise.name = "WristTwist"
	skeleton.add_child(raise)
	raise._ik = ik
	raise._lower_arm = lower_arm
	raise._hand = hand
	raise._target = HumanoidHand.marker(skeleton, "WristTarget")
	raise._pole = HumanoidHand.marker(skeleton, "WristPole")
	ik.set_target_node(0, ik.get_path_to(raise._target))
	ik.set_pole_node(0, ik.get_path_to(raise._pole))
	raise.drive(0.0, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)  # starts down, both modifiers off
	return raise


## Where the DataPad sits on the forearm, in the forearm bone's own frame: `back_m` metres up the
## forearm from the wrist, +X along the forearm towards the hand, +Y out of the arm's OUTER side, where a
## watch is worn. Built from the REST positions of the elbow and wrist rather than from the bone axes,
## which a retargeted rig points anywhere (the hand's Y does not even follow the forearm here). The
## skeleton's own scale is taken out, so whatever hangs there keeps its size in metres.
static func mount_transform(skeleton: Skeleton3D, lower_arm: int, hand: int, back_m: float) -> Transform3D:
	var rest_lower: Transform3D = skeleton.get_bone_global_rest(lower_arm)
	var elbow: Vector3 = rest_lower.origin
	var wrist: Vector3 = skeleton.get_bone_global_rest(hand).origin
	var along: Vector3 = (wrist - elbow).normalized()
	# Outer side: away from the body's midline (a humanoid rig is centred on x = 0), square to the arm.
	var side := Vector3(signf(elbow.x) if elbow.x != 0.0 else 1.0, 0.0, 0.0)
	var outward: Vector3 = (side - along * side.dot(along)).normalized()
	var unit: float = 1.0 / maxf(skeleton.global_basis.get_scale().x if skeleton.is_inside_tree() else 1.0, 1e-6)
	var device := Transform3D(Basis(along, outward, along.cross(outward)).scaled(Vector3.ONE * unit),
			wrist - along * back_m * unit)
	return rest_lower.affine_inverse() * device


## Tell the twist where the screen is on the device it carries (`screen_centre`, in the device's frame,
## whose +Y is the screen's normal), given where the device hangs on the forearm (mount_transform).
func set_screen(mount: Transform3D, screen_centre: Vector3) -> void:
	_screen_local = mount * screen_centre
	_normal_local = (mount.basis * Vector3.UP).normalized()


## Once a frame, before the skeleton is posed: blend in by `weight` (0..1, eased here), the wrist on
## `wrist`, the elbow bent towards `pole`, the screen turned towards `eye` -- all three in the SKELETON's
## space, written as they are: never worked out from world positions each frame. The world is some
## 4e10 m out, where a double tells positions apart by about 8 µm only; a target set through a global
## position came back a few µm off each frame, the IK followed and the elbow multiplied it, and the
## screen shook by up to 0.08 mm in a vehicle -- a pixel, zoomed in (measured, playtest 2026-10-15).
func drive(weight: float, wrist: Vector3, pole: Vector3, eye: Vector3) -> void:
	var w: float = smoothstep(0.0, 1.0, weight)
	active = w > 0.0
	_ik.active = active
	influence = w
	_ik.influence = w
	if not active:
		return
	_target.position = wrist  # the markers are the skeleton's own children: their space is its space
	_pole.position = pole
	_eye_local = eye


func _process_modification_with_delta(_delta: float) -> void:
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null:
		return
	var lower: Transform3D = skeleton.get_bone_global_pose(_lower_arm)
	var wrist: Vector3 = skeleton.get_bone_global_pose(_hand).origin
	var axis: Vector3 = (wrist - lower.origin).normalized()
	var to_eye: Vector3 = _eye_local - lower * _screen_local
	var want: Vector3 = to_eye - axis * to_eye.dot(axis)
	var normal: Vector3 = lower.basis * _normal_local
	var have: Vector3 = normal - axis * normal.dot(axis)
	if want.length() > 1e-5 and have.length() > 1e-5:
		var turn: float = have.normalized().signed_angle_to(want.normalized(), axis)
		lower = Transform3D(Basis(axis, turn) * lower.basis, lower.origin)
		skeleton.set_bone_global_pose(_lower_arm, lower)


## `node`'s transform in `ancestor`'s frame, multiplied up from the local transforms in between: exact
## whatever the world coordinates are, where going through two global transforms is not (see drive).
static func local_to(node: Node3D, ancestor: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf

