extends RefCounted

## Turns a FlowHMR motion capture (.npz, AMASS / SMPL-H layout) into an Animation for our humanoid rig.
##
## FlowHMR reconstructs a body motion from a phone video and writes it as SMPL-H parameters:
##   poses  (frames, 156)  axis-angle local rotation of 52 joints (22 body + 2 x 15 fingers)
##   trans  (frames, 3)    root translation, metres, Y up
##   mocap_framerate       frames per second
##
## The conversion is the one build_retargeted_animations.gd uses for the UAL library, with SMPL as the
## source rig: every SMPL joint rests with an IDENTITY global rotation in a T-pose, so a joint's posed
## global rotation already is "how far it turned from its rest". That turn is applied to the target bone
## from a neutral where the target bone points the way the SMPL bone points (our character rests in an
## A-pose). Bone lengths stay the character's own; only the pelvis position is carried, scaled to its legs.
##
## Fingers (the 30 SMPL-H hand joints) are optional. Unlike the UAL library, SMPL-H's reference hand -- all
## rotations zero -- is a nearly flat hand whose phalanges bend 3-12 degrees, and this character's rest
## hand bends 7-21: close enough to apply FlowHMR's ABSOLUTE finger rotations on the character's own rest
## direction without the over-curl that freezes the UAL fingers. finger_strength still scales them, from
## 0 (the character's rest hand) to 1 (the capture verbatim).

## SMPL-H hand joints (22..51) -> humanoid profile bone, in SMPL-H order: per side index, middle, pinky,
## ring, thumb, three segments each, the first of each finger hanging off the wrist.
const HAND_GROUPS: Array[String] = ["Index", "Middle", "Little", "Ring", "Thumb"]
const FINGER_SEGMENTS: Array[String] = ["Proximal", "Intermediate", "Distal"]
const THUMB_SEGMENTS: Array[String] = ["Metacarpal", "Proximal", "Distal"]
const WRISTS: PackedInt32Array = [20, 21]

## SMPL body joints (the first 22 of SMPL-H) -> humanoid profile bone, in SMPL order.
const SMPL_TO_PROFILE: Array[StringName] = [
	&"Hips", &"LeftUpperLeg", &"RightUpperLeg", &"Spine",
	&"LeftLowerLeg", &"RightLowerLeg", &"Chest", &"LeftFoot",
	&"RightFoot", &"UpperChest", &"LeftToes", &"RightToes",
	&"Neck", &"LeftShoulder", &"RightShoulder", &"Head",
	&"LeftUpperArm", &"RightUpperArm", &"LeftLowerArm", &"RightLowerArm",
	&"LeftHand", &"RightHand",
]
const SMPL_PARENT: PackedInt32Array = [-1, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 9, 12, 13, 14, 16, 17, 18, 19]

## Joint positions of the SMPL neutral template (metres; +X = the body's left, +Y up, +Z forward).
## Only used for bone DIRECTIONS (rest alignment) and the leg length (height scale), so the template's
## average body is close enough whatever the capture's shape parameters.
const SMPL_JOINTS: PackedVector3Array = [
	Vector3(-0.0018, -0.2233, 0.0282), Vector3(0.0695, -0.3141, 0.0239),
	Vector3(-0.0677, -0.3147, 0.0215), Vector3(-0.0025, -0.1037, 0.0124),
	Vector3(0.1040, -0.6754, 0.0164), Vector3(-0.1056, -0.6721, 0.0177),
	Vector3(0.0056, 0.0322, 0.0279), Vector3(0.0884, -1.0948, -0.0274),
	Vector3(-0.0918, -1.0975, -0.0233), Vector3(0.0050, 0.0821, 0.0263),
	Vector3(0.1199, -1.1563, 0.0927), Vector3(-0.1202, -1.1515, 0.0960),
	Vector3(-0.0137, 0.2939, -0.0076), Vector3(0.0717, 0.1915, -0.0015),
	Vector3(-0.0830, 0.1904, -0.0042), Vector3(0.0105, 0.3576, 0.0388),
	Vector3(0.1618, 0.2236, -0.0189), Vector3(-0.1517, 0.2238, -0.0183),
	Vector3(0.4202, 0.2081, -0.0412), Vector3(-0.4196, 0.2110, -0.0420),
	Vector3(0.6720, 0.2162, -0.0461), Vector3(-0.6767, 0.2140, -0.0429),
]

## Bones that keep the character's own rest direction: their two rests differ in build, not in pose
## (same list as build_retargeted_animations.gd).
const KEEP_OWN_DIRECTION: Array[StringName] = [&"LeftShoulder", &"RightShoulder", &"Neck", &"Head"]

## SMPL's zero-pose head does not look straight ahead, it looks UP: on the SMPL-H template the ear-to-eye
## line climbs 17 degrees, against 3-5 degrees on a capture of someone looking level at the camera. Our
## character's rest head looks level, so it is taken to be the SMPL head pitched up by this much (deg);
## without it every capture bows the head ~13 degrees.
const SMPL_HEAD_PITCH_UP_DEG: float = 13.0

## Joint indices used to find the ground and the leg length.
const PELVIS := 0
const ANKLES: PackedInt32Array = [7, 8]


## Everything read from the .npz, or an error message.
class Capture extends RefCounted:
	var error: String = ""
	var frames: int = 0
	var fps: float = 30.0
	var poses: PackedFloat32Array = []  # frames x stride, axis-angle triplets
	var stride: int = 0
	var trans: PackedFloat32Array = []  # frames x 3


## What the conversion produced, with numbers worth printing.
class Result extends RefCounted:
	var error: String = ""
	var animation: Animation
	var frames: int = 0
	var fps: float = 0.0
	var mapped_bones: int = 0
	var height_scale: float = 1.0
	var travel_m: float = 0.0


static func load_capture(path: String) -> Capture:
	var capture: Capture = Capture.new()
	var zip: ZIPReader = ZIPReader.new()
	if zip.open(path) != OK:
		capture.error = "cannot open %s" % path
		return capture
	var poses: Dictionary = _read_npy(zip, "poses.npy")
	var trans: Dictionary = _read_npy(zip, "trans.npy")
	var rate: Dictionary = _read_npy(zip, "mocap_framerate.npy")
	zip.close()
	for array in [poses, trans]:
		if array.has("error"):
			capture.error = array["error"]
			return capture
	# The web demo writes (frames, 156), the CLI (frames, 52, 3): same bytes, C order.
	var shape: Array = poses["shape"]
	if shape.size() == 3 and shape[2] == 3:
		shape = [shape[0], shape[1] * 3]
	if shape.size() != 2 or shape[1] < 66 or shape[1] % 3 != 0:
		capture.error = "poses has shape %s, expected (frames, 3 x joints >= 66) or (frames, joints, 3)" % [shape]
		return capture
	capture.frames = shape[0]
	capture.stride = shape[1]
	capture.poses = poses["data"]
	capture.trans = trans["data"]
	if capture.trans.size() != capture.frames * 3:
		capture.error = "trans holds %d values for %d frames" % [capture.trans.size(), capture.frames]
		return capture
	if not rate.has("error") and rate["data"].size() > 0:
		capture.fps = float(rate["data"][0])
	return capture


## Builds the animation. `prefix` is the skeleton's path from the AnimationPlayer's root node
## ("Armature/GeneralSkeleton" for human_puppet.tscn). With `in_place`, the pelvis keeps its height and
## sway but not its travel across the floor. `finger_strength` 0 leaves the hands at the character's rest.
static func convert(
	capture: Capture,
	skeleton: Skeleton3D,
	prefix: String,
	in_place: bool,
	finger_strength: float = 1.0,
	head_pitch_up_deg: float = SMPL_HEAD_PITCH_UP_DEG
) -> Result:
	var result: Result = Result.new()
	result.frames = capture.frames
	result.fps = capture.fps

	var names: Array[StringName] = SMPL_TO_PROFILE.duplicate()
	var parents: PackedInt32Array = SMPL_PARENT.duplicate()
	var with_fingers: bool = finger_strength > 0.0 and capture.stride >= 52 * 3
	if with_fingers:
		_append_hands(names, parents)

	var target_of: PackedInt32Array = []  # SMPL joint -> target bone index (-1 if absent)
	for joint in names.size():
		var bone: int = skeleton.find_bone(names[joint])
		target_of.append(bone)
		if bone != -1:
			result.mapped_bones += 1
	if target_of[PELVIS] == -1:
		result.error = "the skeleton has no 'Hips' bone: is the glTF imported with humanoid retargeting?"
		return result

	var smpl_of: Dictionary = {}  # target bone index -> SMPL joint
	for joint in target_of.size():
		if target_of[joint] != -1:
			smpl_of[target_of[joint]] = joint

	# SMPL frame -> skeleton space. Measured on the rig rather than assumed, so a skeleton node turned
	# by the glTF import (Blender's -Z forward, a centimetre armature...) converts the same way.
	var axes: Basis = _rig_axes(skeleton)
	var to_rig: Quaternion = axes.get_rotation_quaternion()

	var order: PackedInt32Array = _parents_first(skeleton)
	var global_rest: Dictionary = {}
	for bone in order:
		global_rest[bone] = skeleton.get_bone_global_rest(bone).basis.get_rotation_quaternion()
	var aligned_rest: Dictionary = _align_rests(skeleton, order, smpl_of, global_rest, to_rig)
	var head: int = skeleton.find_bone(&"Head")
	if aligned_rest.has(head):
		# Turning about the body's left axis by a positive angle lowers the face, so raise it with a negative one.
		var raise: Quaternion = Quaternion(axes.x.normalized(), -deg_to_rad(head_pitch_up_deg))
		aligned_rest[head] = raise * (aligned_rest[head] as Quaternion)

	var animation: Animation = Animation.new()
	animation.length = maxf(0.0, float(capture.frames - 1) / capture.fps)
	animation.loop_mode = Animation.LOOP_LINEAR
	var rotation_track: Dictionary = {}
	for bone in smpl_of:
		var track: int = animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, NodePath("%s:%s" % [prefix, skeleton.get_bone_name(bone)]))
		rotation_track[bone] = track
	var hips: int = target_of[PELVIS]
	var hips_track: int = animation.add_track(Animation.TYPE_POSITION_3D)
	animation.track_set_path(hips_track, NodePath("%s:%s" % [prefix, skeleton.get_bone_name(hips)]))

	# Heading: the capture faces wherever the camera stood. Turn it so the first frame faces forward.
	var heading: Quaternion = _heading_fix(capture)

	# Ground and leg length, from forward kinematics on the template skeleton.
	var smpl_globals: Array = []  # per frame: Array[Quaternion] per SMPL joint, SMPL frame
	var pelvis_pos: PackedVector3Array = []
	var lowest_ankle: float = INF
	for frame in capture.frames:
		var globals: Array = _smpl_globals(capture, frame, heading, parents)
		smpl_globals.append(globals)
		var positions: PackedVector3Array = _smpl_positions(capture, frame, heading, globals)
		pelvis_pos.append(positions[PELVIS])
		for ankle in ANKLES:
			lowest_ankle = minf(lowest_ankle, positions[ankle].y)

	var rig_hips: Vector3 = skeleton.get_bone_global_rest(hips).origin
	var rig_ankle: Vector3 = skeleton.get_bone_global_rest(target_of[ANKLES[0]]).origin
	var rig_up: Vector3 = axes.y.normalized()
	var rig_leg: float = (rig_hips - rig_ankle).dot(rig_up)
	var smpl_leg: float = SMPL_JOINTS[PELVIS].y - SMPL_JOINTS[ANKLES[0]].y
	var scale: float = rig_leg / smpl_leg
	result.height_scale = scale
	var hips_parent: int = skeleton.get_bone_parent(hips)
	var parent_rest: Transform3D = Transform3D()
	if hips_parent != -1:
		parent_rest = skeleton.get_bone_global_rest(hips_parent)

	for frame in capture.frames:
		var time: float = float(frame) / capture.fps
		var globals: Array = smpl_globals[frame]
		var posed: Dictionary = {}  # target bone -> posed global rotation, skeleton space
		for bone in order:
			var parent: int = skeleton.get_bone_parent(bone)
			var parent_posed: Quaternion = posed.get(parent, Quaternion())
			if not smpl_of.has(bone):
				posed[bone] = parent_posed * skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
				continue
			var turn: Quaternion = to_rig * (globals[smpl_of[bone]] as Quaternion) * to_rig.inverse()
			posed[bone] = turn * (aligned_rest[bone] as Quaternion)
			var local: Quaternion = (parent_posed.inverse() * (posed[bone] as Quaternion)).normalized()
			if finger_strength < 1.0 and smpl_of[bone] >= SMPL_PARENT.size():
				# Ease the phalanx back toward the character's own hand. Its global pose must follow, or
				# the next phalanx would undo the easing.
				var rest: Quaternion = skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
				local = rest.slerp(local, finger_strength).normalized()
				posed[bone] = parent_posed * local
			animation.rotation_track_insert_key(rotation_track[bone], time, local)

		var moved: Vector3 = pelvis_pos[frame] - pelvis_pos[0]
		if in_place:
			moved = Vector3.ZERO
		var lift: float = (pelvis_pos[frame].y - lowest_ankle) * scale
		var flat: Vector3 = axes * Vector3(moved.x, 0.0, moved.z) * scale
		var hips_rig: Vector3 = rig_hips - rig_up * rig_hips.dot(rig_up)  # the hips' rest, on the floor plane
		hips_rig += rig_up * (rig_ankle.dot(rig_up) + lift) + flat
		animation.position_track_insert_key(hips_track, time, parent_rest.affine_inverse() * hips_rig)
		result.travel_m = maxf(result.travel_m, Vector2(moved.x, moved.z).length())

	result.animation = animation
	return result


## Axis-angle of one joint at one frame, as a quaternion.
static func _joint_rotation(capture: Capture, frame: int, joint: int) -> Quaternion:
	var base: int = frame * capture.stride + joint * 3
	var axis_angle: Vector3 = Vector3(capture.poses[base], capture.poses[base + 1], capture.poses[base + 2])
	var angle: float = axis_angle.length()
	if angle < 0.000001:
		return Quaternion()
	return Quaternion(axis_angle / angle, angle)


## Global rotation of the SMPL joints (`parents`: body only, or body + hands) at one frame, SMPL frame,
## heading-corrected.
static func _smpl_globals(capture: Capture, frame: int, heading: Quaternion, parents: PackedInt32Array) -> Array:
	var globals: Array = []
	for joint in parents.size():
		var parent: int = parents[joint]
		var parent_global: Quaternion = heading if parent == -1 else globals[parent]
		globals.append((parent_global * _joint_rotation(capture, frame, joint)).normalized())
	return globals


static func _smpl_positions(capture: Capture, frame: int, heading: Quaternion, globals: Array) -> PackedVector3Array:
	var positions: PackedVector3Array = []
	var root: Vector3 = Vector3(capture.trans[frame * 3], capture.trans[frame * 3 + 1], capture.trans[frame * 3 + 2])
	for joint in SMPL_JOINTS.size():
		var parent: int = SMPL_PARENT[joint]
		if parent == -1:
			positions.append(heading * (root + SMPL_JOINTS[PELVIS]))
			continue
		var offset: Vector3 = SMPL_JOINTS[joint] - SMPL_JOINTS[parent]
		positions.append(positions[parent] + (globals[parent] as Quaternion) * offset)
	return positions


## Adds the 30 SMPL-H hand joints (22..51) after the body ones: left hand off joint 20, right off 21.
static func _append_hands(names: Array[StringName], parents: PackedInt32Array) -> void:
	for side in 2:
		var prefix: String = "Left" if side == 0 else "Right"
		for group in HAND_GROUPS:
			var segments: Array[String] = THUMB_SEGMENTS if group == "Thumb" else FINGER_SEGMENTS
			for segment in segments.size():
				parents.append(WRISTS[side] if segment == 0 else names.size() - 1)
				names.append(StringName(prefix + group + segments[segment]))


## True for a phalanx bone of the humanoid profile.
static func _is_finger(bone: StringName) -> bool:
	for group in HAND_GROUPS:
		if String(bone).contains(group):
			return true
	return false


## A yaw that turns the first frame's pelvis to face +Z (SMPL forward).
static func _heading_fix(capture: Capture) -> Quaternion:
	var forward: Vector3 = _joint_rotation(capture, 0, PELVIS) * Vector3.BACK
	forward.y = 0.0
	if forward.length_squared() < 0.000001:
		return Quaternion()
	return Quaternion(Vector3.UP, -atan2(forward.x, forward.z))


## The rig's own body axes in skeleton space: X = its left, Y = up, Z = forward, as SMPL's.
static func _rig_axes(skeleton: Skeleton3D) -> Basis:
	var left: Vector3 = _bone_origin(skeleton, &"LeftUpperLeg") - _bone_origin(skeleton, &"RightUpperLeg")
	var up: Vector3 = _bone_origin(skeleton, &"Head") - _bone_origin(skeleton, &"Hips")
	var forward: Vector3 = left.cross(up).normalized()
	up = forward.cross(left).normalized()
	return Basis(left.normalized(), up, forward)


static func _bone_origin(skeleton: Skeleton3D, bone: StringName) -> Vector3:
	var idx: int = skeleton.find_bone(bone)
	return Vector3.ZERO if idx == -1 else skeleton.get_bone_global_rest(idx).origin


## Swing each target bone so it points along its SMPL twin; forks and leaves inherit their parent's swing.
static func _align_rests(
	skeleton: Skeleton3D, order: PackedInt32Array, smpl_of: Dictionary, global_rest: Dictionary, to_rig: Quaternion
) -> Dictionary:
	var swing: Dictionary = {}
	var aligned: Dictionary = {}
	for bone in order:
		if not smpl_of.has(bone):
			continue
		var turn: Quaternion = swing.get(_mapped_parent(skeleton, bone, smpl_of), Quaternion())
		var child: int = -1
		var bone_name: StringName = skeleton.get_bone_name(bone)
		if not KEEP_OWN_DIRECTION.has(bone_name) and not _is_finger(bone_name):
			child = _single_mapped_child(skeleton, bone, smpl_of)
		if child != -1:
			var own: Vector3 = (skeleton.get_bone_global_rest(child).origin - skeleton.get_bone_global_rest(bone).origin)
			var twin: Vector3 = to_rig * (SMPL_JOINTS[smpl_of[child]] - SMPL_JOINTS[smpl_of[bone]])
			if own.length_squared() > 0.0 and twin.length_squared() > 0.0:
				turn = Quaternion(own.normalized(), twin.normalized())
		swing[bone] = turn
		aligned[bone] = turn * (global_rest[bone] as Quaternion)
	return aligned


static func _mapped_parent(skeleton: Skeleton3D, bone: int, smpl_of: Dictionary) -> int:
	var parent: int = skeleton.get_bone_parent(bone)
	while parent != -1 and not smpl_of.has(parent):
		parent = skeleton.get_bone_parent(parent)
	return parent


## The mapped bone that continues this one, or -1 where the chain forks or ends.
static func _single_mapped_child(skeleton: Skeleton3D, bone: int, smpl_of: Dictionary) -> int:
	var found: int = -1
	for child in skeleton.get_bone_children(bone):
		if not smpl_of.has(child):
			continue
		if found != -1:
			return -1
		found = child
	return found


static func _parents_first(skeleton: Skeleton3D) -> PackedInt32Array:
	var order: PackedInt32Array = []
	var pending: Array[int] = []
	for idx in skeleton.get_bone_count():
		if skeleton.get_bone_parent(idx) == -1:
			pending.append(idx)
	while not pending.is_empty():
		var idx: int = pending.pop_front()
		order.append(idx)
		for child in skeleton.get_bone_children(idx):
			pending.append(child)
	return order


## Minimal .npy reader: little-endian float32 / float64 / int64, C order.
static func _read_npy(zip: ZIPReader, file: String) -> Dictionary:
	if not zip.file_exists(file):
		return {"error": "%s missing from the archive" % file}
	var bytes: PackedByteArray = zip.read_file(file)
	if bytes.size() < 10 or bytes[0] != 0x93 or bytes.slice(1, 6).get_string_from_ascii() != "NUMPY":
		return {"error": "%s is not a .npy array" % file}
	var header_len: int = bytes.decode_u16(8)
	var start: int = 10 + header_len
	if bytes[6] >= 2:
		header_len = bytes.decode_u32(8)
		start = 12 + header_len
	var header: String = bytes.slice(10 if bytes[6] < 2 else 12, start).get_string_from_ascii()
	if header.contains("'fortran_order': True"):
		return {"error": "%s is Fortran-ordered" % file}
	var regex: RegEx = RegEx.create_from_string("'shape':\\s*\\(([^)]*)\\)")
	var shape: Array = []
	var found: RegExMatch = regex.search(header)
	if found != null:
		for part in found.get_string(1).split(",", false):
			shape.append(int(part.strip_edges()))
	var payload: PackedByteArray = bytes.slice(start)
	var data: PackedFloat32Array = []
	if header.contains("'<f4'"):
		data = payload.to_float32_array()
	elif header.contains("'<f8'"):
		data = PackedFloat32Array(payload.to_float64_array())
	elif header.contains("'<i8'"):
		for i in payload.size() / 8:
			data.append(float(payload.decode_s64(i * 8)))
	else:
		return {"error": "%s has an unsupported dtype (%s)" % [file, header]}
	return {"shape": shape, "data": data}
