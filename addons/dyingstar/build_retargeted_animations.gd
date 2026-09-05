@tool
extends EditorScript

## Converts a shared animation library so it plays correctly on a character rigged differently.
##
## The Universal Animation Library ships 254 clips on its own skeleton. A character delivered by an
## artist has the same BONES (both rigs are imported with retargeting, so they share the humanoid
## profile names) but its own rest pose: shoulders, forearms and toes point elsewhere, and the limbs
## have different proportions.
##
## That matters because a rotation track stores an ABSOLUTE local rotation, not an offset from the rest
## pose. Replaying a clip as-is puts the target's bones where the SOURCE's bones were, which is wrong by
## exactly the difference between the two rest poses -- elbows bending the wrong way, head rolling
## instead of turning.
##
## Godot's import-time rest fixer can align the two rests instead, but it does so by MOVING the target's
## bones, and the character's mesh was skinned to its own rest: every bone it straightens deforms the
## body (a belly pushed forward, toes lifting, a lump at the shoulder). This script takes the opposite
## route, and that is why it cannot deform anything: the character's skeleton and mesh are never
## touched, the ANIMATION is rewritten.
##
## For each bone, at each sampled instant, it reads how far the source bone has turned away from its own
## rest IN GLOBAL SPACE, and applies that same turn to the target -- measured from a neutral where the
## target's bones point the way the source's do, so a T-posed library does not land 45 degrees off on an
## A-posed character (see Rig._align_rests). Bones the source does not animate come out at that neutral
## whatever their depth (their turn equals their parent's, which cancels out), so they need no track at
## all and the library stays the size of the original.
##
## Run it from the script editor (File > Run, or Ctrl+Shift+X) after either glTF changes. The output is
## derived: never edit it by hand, regenerate it.

const SOURCE_SCENE := "res://assets/_universe/characters/humanoids/UALDyingStar.glb"
const TARGET_SCENE := "res://assets/_universe/characters/humanoids/man_ddurieux.glb"
const OUTPUT_PATH := "res://assets/_universe/characters/humanoids/man_ddurieux_animations.res"

## Clips are imported at 30 fps, so sampling at 30 Hz reproduces every key without inventing detail.
const SAMPLE_FPS := 30.0

## Bones whose local position carries the body height and sway. Every other bone keeps the target's own
## rest offset, because bone LENGTHS are the one thing a retarget must never copy.
const ROOT_MOTION_BONES: Array[StringName] = [&"Hips", &"Root"]

## Bones left at the character's own rest for the whole library, animation and all. Finger motion does
## not survive a change of hand: replayed here it closes past the anatomical stop until the fingertips
## sink into the palm, whether or not the rest is aligned first -- both were tried. The game has no
## finger-level gameplay to lose, and a relaxed hand reads better than a permanent fist. The day a grip
## pose matters, drop this and author the hand poses on this character instead of importing them.
##
## This only works because the same groups keep their own rest direction below (Rig.KEEP_OWN_DIRECTION):
## a bone with no track lands on the neutral the conversion aims at, so freezing an ALIGNED finger would
## simply make the clench permanent.
const FROZEN_GROUPS: Array[String] = ["Thumb", "Index", "Middle", "Ring", "Little"]

## Clips that keep their finger animation anyway, because the hand GRIPS something. The reason fingers
## are frozen is that an imported curl closes past the anatomical stop and the fingertips sink into the
## palm -- plainly wrong on an open hand. Closed around a steering wheel the same excess is hidden by
## the rim, and a flat hand laid on the wheel is the worse of the two. Add a clip here if its hands
## should hold rather than rest.
const GRIPPING_CLIPS: Array[String] = ["Driving"]

## How much of the imported curl a gripping clip keeps, from 0 (the character's own relaxed hand) to 1
## (the library's curl, verbatim). Neither end is right: at 0 a flat hand rests on the wheel, at 1 the
## fingers close past their stop and cross into the palm, because the two hands are not built the same.
## This is a dial, not a derivation -- set it by eye on the driving pose.
const FINGER_STRENGTH: float = 0.55


## Both skeletons, paired by bone name, with the rest poses the conversion needs precomputed once.
class Rig extends RefCounted:
	## Bones to leave at the character's own rest direction. Aligning a bone only makes sense where the two
	## rigs rest in a different POSE, as the arms do (a T-posed library on an A-posed character). These
	## already rest the same way and differ only in BUILD, so aligning them would import the library's
	## proportions as if they were a pose: the collar bones and neck push the shoulders and head forward
	## (this character's collar bone is 75% longer than the library's), and the fingers clench into fists.
	const KEEP_OWN_DIRECTION: Array[StringName] = [&"LeftShoulder", &"RightShoulder", &"Neck", &"Head"]

	## Same reason, for every phalanx: the humanoid profile names them "<side><group><segment>", so one
	## test covers the thirty of them without a roll call that would drift the day a segment is renamed.
	const FINGER_GROUPS: Array[String] = ["Thumb", "Index", "Middle", "Ring", "Little"]

	var src: Skeleton3D
	var dst: Skeleton3D
	## Target bone indices that also exist in the source, ordered parents first: converting a bone needs
	## its parent's already-converted pose.
	var paired: PackedInt32Array = []
	var source_of: Dictionary = {}  # target bone index -> source bone index
	var src_global_rest: Dictionary = {}  # target bone index -> Quaternion
	var dst_global_rest: Dictionary = {}  # target bone index -> Quaternion
	## The rest the conversion aims at: the target's own rest, swung so each bone POINTS the way the
	## source's bone points. Only a reference frame for the maths -- the skeleton itself is never touched.
	var aligned_rest: Dictionary = {}  # target bone index -> Quaternion

	func _init(source_skeleton: Skeleton3D, target_skeleton: Skeleton3D) -> void:
		src = source_skeleton
		dst = target_skeleton
		for idx in _parents_first(target_skeleton):
			var twin: int = src.find_bone(dst.get_bone_name(idx))
			if twin == -1:
				continue
			paired.append(idx)
			source_of[idx] = twin
			src_global_rest[idx] = src.get_bone_global_rest(twin).basis.get_rotation_quaternion()
			dst_global_rest[idx] = dst.get_bone_global_rest(idx).basis.get_rotation_quaternion()
		_align_rests()

	## Rest poses only match limb for limb by luck: the animation library rests in a T-pose, this
	## character rests in an A-pose, and an animation stored as an offset from the rest would then carry
	## that 45-degree gap into every arm. So swing each target bone until it points along its source twin,
	## and take THAT as the neutral the clips are replayed from.
	##
	## The swing is derived from where the next bone sits, so it only exists for a bone with a single
	## child. A shoulder, a hip or a wrist forks, and a fingertip ends: those inherit their parent's swing,
	## which is also what keeps the spine and the pelvis exactly as the artist built them.
	func _align_rests() -> void:
		var swing: Dictionary = {}
		for idx in paired:
			var turn: Quaternion = swing.get(dst.get_bone_parent(idx), Quaternion())
			var child: int = -1
			if not _keeps_own_direction(dst.get_bone_name(idx)):
				child = _single_paired_child(idx)
			if child != -1:
				var to_child: Vector3 = _bone_axis(dst, idx, child)
				var twin_axis: Vector3 = _bone_axis(src, source_of[idx], source_of[child])
				if to_child.length_squared() > 0.0 and twin_axis.length_squared() > 0.0:
					turn = Quaternion(to_child, twin_axis)
			swing[idx] = turn
			aligned_rest[idx] = turn * dst_global_rest[idx]

	## True for a bone whose two rests differ in build rather than in pose, which must therefore keep the
	## character's own direction and simply follow its parent.
	static func _keeps_own_direction(bone: StringName) -> bool:
		if KEEP_OWN_DIRECTION.has(bone):
			return true
		for group in FINGER_GROUPS:
			if String(bone).contains(group):
				return true
		return false

	## Direction from one bone to the next in the rest pose, in global space, or ZERO if they coincide.
	static func _bone_axis(skeleton: Skeleton3D, from_bone: int, to_bone: int) -> Vector3:
		var span: Vector3 = (skeleton.get_bone_global_rest(to_bone).origin
				- skeleton.get_bone_global_rest(from_bone).origin)
		if span.length() < 0.00001:
			return Vector3.ZERO
		return span.normalized()

	## The bone that continues this one, or -1 where the chain forks or ends and no direction is defined.
	func _single_paired_child(idx: int) -> int:
		var found: int = -1
		for child in dst.get_bone_children(idx):
			if not source_of.has(child):
				continue
			if found != -1:
				return -1
			found = child
		return found

	## Bone indices ordered so a bone always follows its parent. Import order usually satisfies this
	## already, but walking the hierarchy makes the conversion independent of how the glTF was authored.
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


## What one converted clip produced, so the run reports without parsing logs.
class ClipResult extends RefCounted:
	var clip: Animation
	var skipped_tracks: int = 0


func _run() -> void:
	var source: Node = _instantiate(SOURCE_SCENE)
	var target: Node = _instantiate(TARGET_SCENE)
	if source == null or target == null:
		_free_all([source, target])
		return

	var src_skeleton: Skeleton3D = _find(source, "Skeleton3D") as Skeleton3D
	var dst_skeleton: Skeleton3D = _find(target, "Skeleton3D") as Skeleton3D
	var player: AnimationPlayer = _find(source, "AnimationPlayer") as AnimationPlayer
	if src_skeleton == null or dst_skeleton == null or player == null:
		push_error("[DyingStar] retarget: source needs a Skeleton3D and an AnimationPlayer, target a Skeleton3D.")
		_free_all([source, target])
		return

	var rig: Rig = Rig.new(src_skeleton, dst_skeleton)
	if rig.paired.is_empty():
		push_error("[DyingStar] retarget: the two rigs share no bone name. Is retargeting enabled on both glTF?")
		_free_all([source, target])
		return

	var dst_prefix: String = String(target.get_path_to(dst_skeleton))
	var library: AnimationLibrary = AnimationLibrary.new()
	var skipped_tracks: int = 0
	var converted: int = 0

	for clip_name in player.get_animation_list():
		var result: ClipResult = _convert_clip(player.get_animation(clip_name), rig, dst_prefix, clip_name)
		library.add_animation(clip_name, result.clip)
		skipped_tracks += result.skipped_tracks
		converted += 1

	var status: int = ResourceSaver.save(library, OUTPUT_PATH)
	if status != OK:
		push_error("[DyingStar] retarget: could not write %s (error %d)." % [OUTPUT_PATH, status])
		_free_all([source, target])
		return

	print("[DyingStar] retarget: %d clips converted onto %d shared bones, tracks under '%s' -> %s"
			% [converted, rig.paired.size(), dst_prefix, OUTPUT_PATH])
	if skipped_tracks > 0:
		push_warning("[DyingStar] retarget: %d track(s) targeted no shared bone and were dropped." % skipped_tracks)
	_free_all([source, target])


func _convert_clip(source_clip: Animation, rig: Rig, dst_prefix: String, clip_name: String) -> ClipResult:
	var result: ClipResult = ClipResult.new()
	var out: Animation = Animation.new()
	out.length = source_clip.length
	out.loop_mode = source_clip.loop_mode
	out.step = source_clip.step

	# Which source track feeds which bone, resolved once instead of at every sampled instant.
	var rotation_track: Dictionary = {}  # target bone index -> source track index
	var position_track: Dictionary = {}
	for track in source_clip.get_track_count():
		var path: NodePath = source_clip.track_get_path(track)
		var bone: StringName = &""
		if path.get_subname_count() > 0:
			bone = path.get_subname(0)
		var idx: int = rig.dst.find_bone(bone)
		if idx == -1 or not rig.source_of.has(idx):
			result.skipped_tracks += 1
			continue
		if _is_frozen(bone) and not GRIPPING_CLIPS.has(clip_name):
			continue
		var kind: int = source_clip.track_get_type(track)
		if kind == Animation.TYPE_ROTATION_3D:
			rotation_track[idx] = track
		elif kind == Animation.TYPE_POSITION_3D and ROOT_MOTION_BONES.has(bone):
			position_track[idx] = track

	# One output track per bone the source actually animates. A bone with no source track provably keeps
	# the target's own rest, so writing one would only repeat what the skeleton already holds.
	var out_rotation: Dictionary = {}
	for idx in rotation_track:
		out_rotation[idx] = _add_track(out, Animation.TYPE_ROTATION_3D, dst_prefix, rig.dst.get_bone_name(idx))
	var out_position: Dictionary = {}
	for idx in position_track:
		out_position[idx] = _add_track(out, Animation.TYPE_POSITION_3D, dst_prefix, rig.dst.get_bone_name(idx))

	for time in _sample_times(source_clip):
		_convert_pose(source_clip, rig, time, rotation_track, out, out_rotation)
		for idx in position_track:
			var moved: Vector3 = _convert_position(source_clip, rig, position_track[idx], idx, time)
			out.position_track_insert_key(out_position[idx], time, moved)

	result.clip = out
	return result


## Write one instant of the clip: walk the hierarchy parents first, carrying each bone's global rotation
## in the source rig and the global rotation it becomes on the target rig.
func _convert_pose(
	source_clip: Animation,
	rig: Rig,
	time: float,
	rotation_track: Dictionary,
	out: Animation,
	out_rotation: Dictionary
) -> void:
	var src_global: Dictionary = {}
	var dst_global: Dictionary = {}
	for idx in rig.paired:
		var twin: int = rig.source_of[idx]
		var local: Quaternion = rig.src.get_bone_rest(twin).basis.get_rotation_quaternion()
		if rotation_track.has(idx):
			local = source_clip.rotation_track_interpolate(rotation_track[idx], time)

		var parent: int = rig.dst.get_bone_parent(idx)
		var src_parent: Quaternion = src_global.get(parent, Quaternion())
		var dst_parent: Quaternion = dst_global.get(parent, Quaternion())

		# How far this bone turned away from ITS OWN rest, in global space: the one quantity that means
		# the same thing on two rigs of different shape.
		var posed: Quaternion = src_parent * local
		var turn: Quaternion = posed * rig.src_global_rest[idx].inverse()
		var becomes: Quaternion = turn * rig.aligned_rest[idx]

		src_global[idx] = posed
		dst_global[idx] = becomes
		if out_rotation.has(idx):
			var local_dst: Quaternion = (dst_parent.inverse() * becomes).normalized()
			if _is_frozen(rig.dst.get_bone_name(idx)):
				# A gripping clip got here with its finger tracks kept; ease them back toward the hand
				# this character actually has, rather than closing them the whole way.
				var relaxed: Quaternion = rig.dst.get_bone_rest(idx).basis.get_rotation_quaternion()
				local_dst = relaxed.slerp(local_dst, FINGER_STRENGTH).normalized()
			out.rotation_track_insert_key(out_rotation[idx], time, local_dst)


## Carry the source's motion away from its rest, scaled to the target's build, so a taller character does
## not sink into the floor. The bone lengths themselves stay the target's own.
func _convert_position(source_clip: Animation, rig: Rig, track: int, idx: int, time: float) -> Vector3:
	var twin: int = rig.source_of[idx]
	var src_rest: Vector3 = rig.src.get_bone_rest(twin).origin
	var dst_rest: Vector3 = rig.dst.get_bone_rest(idx).origin
	var scale: float = 1.0
	if src_rest.length() > 0.0001:
		scale = dst_rest.length() / src_rest.length()
	var sampled: Vector3 = source_clip.position_track_interpolate(track, time)
	return dst_rest + (sampled - src_rest) * scale


## True for a bone the library must not animate at all, so it stays at the character's own rest.
func _is_frozen(bone: StringName) -> bool:
	for group in FROZEN_GROUPS:
		if String(bone).contains(group):
			return true
	return false


func _add_track(clip: Animation, type: int, prefix: String, bone: StringName) -> int:
	var track: int = clip.add_track(type)
	clip.track_set_path(track, NodePath("%s:%s" % [prefix, bone]))
	clip.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
	return track


## Instants to rebuild the clip at. The conversion is not a per-key rewrite -- a bone's result depends on
## its parent's converted pose -- so the whole pose is resampled on the import's own 30 Hz grid.
func _sample_times(clip: Animation) -> PackedFloat32Array:
	var times: PackedFloat32Array = []
	var steps: int = maxi(1, int(round(clip.length * SAMPLE_FPS)))
	for step in steps + 1:
		times.append(minf(float(step) / SAMPLE_FPS, clip.length))
	return times


func _instantiate(path: String) -> Node:
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		push_error("[DyingStar] retarget: cannot load %s." % path)
		return null
	return scene.instantiate()


func _find(root: Node, type_name: String) -> Node:
	var found: Array[Node] = root.find_children("*", type_name, true, false)
	if found.is_empty():
		return null
	return found[0]


func _free_all(nodes: Array) -> void:
	for node in nodes:
		if node != null:
			node.free()
