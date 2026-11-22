class_name HumanAppearance
extends Node

## Gives the puppet it sits in the body of a CharacterAppearance: the baked mesh (HumanMeshCache) on the
## puppet's own skeleton, whose rest positions and motion_scale are refitted to that body, with the
## materials and colours of the look. Until the bake is ready the puppet keeps the body it has (the
## imported character): it never shows nothing, nor a T-pose.
##
## Same skeleton, same bone names, same rest rotations: the animation library, the IKs and every bone
## attachment keep working; what measured the old rest (CharacterAnimator.on_rest_changed) is told
## through appearance_applied. A colour-only change swaps materials and instance uniforms, no bake.
##
## The body and the head are two meshes. A face seen close up (face_life) gets a second head, baked with
## blend shapes (HumanBuilder.LIFE_SHAPES), which FaceLife drives; the plain head comes back when it
## moves away.
##
## Nothing happens on a dedicated server: there, an avatar is never drawn.

## Emitted once the new body is on the skeleton (rests moved, meshes swapped).
signal appearance_applied

## Seed a random look from this text at start (a mannequin's name, say); empty = keep the imported body
## until set_appearance is called.
@export var random_seed_text: String = ""
## Named look applied at start instead (CharacterAppearance.preset: "default_male", "default_female");
## empty = none. random_seed_text wins when both are set.
@export var preset_name: String = ""
## Bake bodies with their levels of detail. Off for the character creator's preview: a slider drag
## then shows its body in ~40 ms instead of ~150.
@export var use_lods: bool = true
## Give the face its blend shapes (blinks, gaze, mouth, brows: HumanBuilder.LIFE_SHAPES), driven by
## FaceLife. One more bake of the head (~100 ms on a worker) and ~10 MB of video memory while on: for
## faces seen close up -- PlayerClient turns it on by distance (set_life), the creator keeps it on.
@export var face_life: bool = false

const BODY_NODE_NAME := &"HumanBody"
## The BoneAttachment3D on the Head bone that carries the hair (HairStrands), and the hair under it.
const HAIR_ATTACHMENT_NAME := &"HumanHair"
const HAIR_NODE_NAME := &"Hair"
## Share of a style's length kept at the shortest cut (hair_length = 0): the hair shaders clip the rest.
const MIN_HAIR_KEPT: float = 0.4
const HEAD_NODE_NAME := &"HumanHead"

var appearance: CharacterAppearance = null
var _skeleton: Skeleton3D = null
var _mesh: MeshInstance3D = null
var _head: MeshInstance3D = null
var _hair: MeshInstance3D = null
var _live: HumanBuilder.Baked = null  # the live head shown, or null (the plain one)
var _shape_index: Dictionary = {}  # life shape name -> blend shape index of the live head
var _smiles: Dictionary = {}  # smile / happy shape -> weight held by set_face_shape
var _near: bool = true
var _baked: HumanBuilder.Baked = null
var _shown_shape: int = -1
var _wanted_shape: int = -1
var _layers: int = 1
var _cast_shadow: GeometryInstance3D.ShadowCastingSetting = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _ready() -> void:
	set_process(false)
	if OS.has_feature("dedicated_server"):
		return
	_skeleton = _find_skeleton()
	if _skeleton != null and not _skeleton.has_meta(&"human_refit"):
		HumanMeshCache.set_template(_skeleton)
	HumanBuilder.warm()  # start loading the bank on a worker as soon as a puppet exists
	if random_seed_text != "":
		set_appearance(CharacterAppearance.from_uuid(random_seed_text))
	elif preset_name != "":
		set_appearance(CharacterAppearance.preset(preset_name))


## Wear [param look] (null is ignored), within the creator's limits (CreatorLimits.limit: a face pushed past what
## looks human is shown less pushed; [param look] itself is left as it is). The body follows when baked, the colours
## at once if the shape is already shown.
func set_appearance(look: CharacterAppearance) -> void:
	if look == null or OS.has_feature("dedicated_server"):
		return
	appearance = CreatorLimits.limit(look)
	if _skeleton == null:
		_skeleton = _find_skeleton()
	if _skeleton == null:
		return
	var previous: int = _wanted_shape
	_wanted_shape = appearance.shape_hash()
	if previous != -1 and previous != _wanted_shape and previous != _shown_shape:
		HumanMeshCache.cancel(previous)
		HumanMeshCache.cancel(previous, true)  # asked for, never shown, not wanted any more
	if _wanted_shape == _shown_shape:
		_apply_look()
		return
	if not (HumanBuilder.warm() and _take_bakes()):
		set_process(true)  # the bank is loading or the body baking: _process takes it from there


## Wear [param look] now, baking on this thread if needed (previews, tests); within the limits, as set_appearance.
func set_appearance_now(look: CharacterAppearance) -> void:
	if look == null or OS.has_feature("dedicated_server"):
		return
	appearance = CreatorLimits.limit(look)
	if _skeleton == null:
		_skeleton = _find_skeleton()
	if _skeleton == null:
		return
	if not HumanMeshCache.has_template() and not _skeleton.has_meta(&"human_refit"):
		HumanMeshCache.set_template(_skeleton)
	HumanBuilder.prepare()
	_wanted_shape = appearance.shape_hash()
	_apply(HumanMeshCache.build_now(appearance, use_lods))
	if face_life:
		_show_live(HumanMeshCache.build_now(appearance, false, true))


## Close-up materials (the skin's own lighting, micro relief, wet eyes) or the light ones: an avatar seen
## from afar does not need the first, and they cost per light and pixel. PlayerClient switches a remote
## avatar by its distance; our own body, the creator's figure and anything else stay close-up.
func set_detail(near: bool) -> void:
	if near == _near:
		return
	_near = near
	_apply_look()


## True once a baked body is shown (not the imported one).
func is_applied() -> bool:
	return _shown_shape != -1


## The MeshInstance3D of the baked body, or null while the imported one is shown.
func body_mesh() -> MeshInstance3D:
	return _mesh


## The MeshInstance3D of the hair (unskinned, under a BoneAttachment3D on the Head bone), or null.
func hair_mesh() -> MeshInstance3D:
	return _hair


## The MeshInstance3D of the baked head (face, eyes, mouth), or null while the imported body is shown.
func head_mesh() -> MeshInstance3D:
	return _head


## The skeleton the body hangs on, or null.
func skeleton() -> Skeleton3D:
	return _skeleton


## The grown head of hair's asset shown (its style), or null.
func hair_asset() -> HumanAssetData:
	return _baked.hair_asset if _baked != null else null


## The capsules the hair keeps out of (HumanBuilder.Baked.hair_colliders): [bone name, a, b, radius].
func hair_colliders() -> Array:
	return _baked.hair_colliders if _baked != null else []


## The beard's length as the strands shader measures along its hairs (m: BeardGroom's colour), 0 without hairs.
func beard_length() -> float:
	var cut: BeardCut = appearance.beard_grown() if appearance != null else null
	return 0.0 if cut == null or cut.shell_only() else cut.hair_length() * 1.15


## Turn the face's blend shapes on or off (see face_life). The live head shows once baked.
func set_life(on: bool) -> void:
	if on == face_life:
		return
	face_life = on
	if on:
		set_process(appearance != null)
		return
	if _wanted_shape != -1:
		HumanMeshCache.cancel(_wanted_shape, true)
	if _live != null:
		_live = null
		_shape_index.clear()
		_head.mesh = _baked.head_mesh
		_apply_look()


## True while the head shown has its blend shapes (set_face_shape does something).
func is_live() -> bool:
	return _live != null


## Blend shape index of a life shape (HumanBuilder.LIFE_SHAPES name) on head_mesh(), -1 when not live.
func face_shape_index(shape: StringName) -> int:
	return _shape_index.get(shape, -1)


## Set a life shape ("jaw_open", "blink_left"...), 0..1. Nothing while the head is not live.
func set_face_shape(shape: StringName, weight: float) -> void:
	var index: int = _shape_index.get(shape, -1)
	if index != -1:
		_head.set_blend_shape_value(index, weight)
	if shape == &"smile" or shape == &"happy":
		_smiles[shape] = weight
		set_smile(maxf(_smiles.get(&"smile", 0.0), _smiles.get(&"happy", 0.0)))


## How much the face smiles now, 0..1: the skin folds (nasolabial folds, dimples) with it.
func set_smile(amount: float) -> void:
	if _head != null:
		_head.set_instance_shader_parameter(&"face_motion", Vector4(amount, 0.0, 0.0, 0.0))


func _process(_delta: float) -> void:
	if appearance == null:
		set_process(false)
		return
	if not HumanBuilder.warm():
		return
	HumanMeshCache.poll()
	if _shown_shape != _wanted_shape:
		_take_bakes()
		return
	if face_life and _live == null:
		var live: HumanBuilder.Baked = HumanMeshCache.request(appearance, false, true)
		if live == null:
			return
		_show_live(live)
	set_process(false)


## Show the wanted shape if its bakes are ready (queued once, else); true when shown. A face alive now stays
## alive: its new body waits for the new live head, baked alongside, and both show together with the
## weights the face had -- else every slider drag dropped an expression (and a blink, a glance) for the
## ~100 ms between the two bakes.
func _take_bakes() -> bool:
	var baked: HumanBuilder.Baked = HumanMeshCache.request(appearance, use_lods)
	var live: HumanBuilder.Baked = null
	if face_life and _live != null:
		live = HumanMeshCache.request(appearance, false, true)
		if live == null:
			return false
	if baked == null:
		return false
	var weights: Dictionary = _face_weights()
	var folds: Variant = _head.get_instance_shader_parameter(&"face_motion") if _head != null else null
	_apply(baked)
	if live != null:
		_show_live(live, weights)
		if folds != null:
			_head.set_instance_shader_parameter(&"face_motion", folds)
	return true


## The live head's blend shape weights by name ({} when the head is plain).
func _face_weights() -> Dictionary:
	var weights: Dictionary = {}
	if _live != null and _head != null:
		for shape: StringName in _shape_index:
			weights[shape] = _head.get_blend_shape_value(_shape_index[shape])
	return weights


## Swap the plain head for its live twin: same vertices at rest, plus the blend shapes, set to [param weights]
## (by name) until FaceLife drives them.
func _show_live(live: HumanBuilder.Baked, weights: Dictionary = {}) -> void:
	if live == null or live.shape_hash != _shown_shape or _head == null:
		return
	_live = live
	_head.mesh = live.head_mesh
	_shape_index.clear()
	for k in live.head_mesh.get_blend_shape_count():
		_shape_index[live.head_mesh.get_blend_shape_name(k)] = k
		_head.set_blend_shape_value(k, weights.get(live.head_mesh.get_blend_shape_name(k), 0.0))
	_apply_look()


func _apply(baked: HumanBuilder.Baked) -> void:
	if baked.shape_hash != _wanted_shape:
		return  # a newer look was asked for meanwhile
	_refit_skeleton(baked)
	_swap_meshes(baked)
	_baked = baked
	_live = null
	_shape_index.clear()
	_shown_shape = baked.shape_hash
	_apply_look()
	appearance_applied.emit()
	if face_life:
		set_process(true)  # the live head of this new body follows


## Move the skeleton's rests to the baked joints, keeping each bone's rest rotation.
func _refit_skeleton(baked: HumanBuilder.Baked) -> void:
	var bank: HumanBank = HumanMorph.shared().bank
	var head: int = _skeleton.find_bone("Head")
	if not _skeleton.has_meta(&"human_refit") and head != -1:
		# Where the imported character's head rested: the first-person eye was placed for it
		# (CharacterAnimator._sync_eye_height).
		_skeleton.set_meta(&"template_head_rest", _skeleton.get_bone_global_rest(head).origin)
	var globals: Array[Transform3D] = []
	globals.resize(_skeleton.get_bone_count())
	for i in _skeleton.get_bone_count():
		var b: int = bank.bone_names.find(_skeleton.get_bone_name(i))
		var parent: int = _skeleton.get_bone_parent(i)
		if b != -1:
			globals[i] = baked.rests[b]
		else:  # a bone the bank does not know: carried by its parent as it was
			var parent_global: Transform3D = globals[parent] if parent != -1 else Transform3D.IDENTITY
			globals[i] = parent_global * _skeleton.get_bone_rest(i)
	for i in _skeleton.get_bone_count():
		var parent: int = _skeleton.get_bone_parent(i)
		var local: Transform3D = globals[parent].affine_inverse() * globals[i] if parent != -1 else globals[i]
		_skeleton.set_bone_rest(i, local)
		_skeleton.set_bone_pose_position(i, local.origin)  # only the hips' position is animated
	_skeleton.motion_scale = baked.hips_height
	_skeleton.set_meta(&"human_refit", true)


## Replace the skinned meshes on the skeleton (the imported ones, or a previous bake) by the baked body.
func _swap_meshes(baked: HumanBuilder.Baked) -> void:
	var first: bool = true
	for child in _skeleton.get_children():
		var old := child as MeshInstance3D
		if old == null or old.skin == null:
			continue
		if first:  # the render layer and shadow mode the player gave its body (own body, distance LOD)
			_layers = old.layers
			_cast_shadow = old.cast_shadow
			first = false
		_skeleton.remove_child(old)
		old.queue_free()
	_mesh = _skinned(BODY_NODE_NAME, baked.mesh, baked.skin)
	_head = _skinned(HEAD_NODE_NAME, baked.head_mesh, baked.skin)
	var carrier := _skeleton.get_node_or_null(NodePath(HAIR_ATTACHMENT_NAME))
	if carrier != null:
		_skeleton.remove_child(carrier)
		carrier.queue_free()
	_hair = null
	if baked.hair_mesh != null:
		var attachment := BoneAttachment3D.new()
		attachment.name = HAIR_ATTACHMENT_NAME
		_skeleton.add_child(attachment)
		attachment.bone_name = "Head"
		_hair = MeshInstance3D.new()
		_hair.name = HAIR_NODE_NAME
		_hair.mesh = baked.hair_mesh
		_hair.transform = baked.hair_transform
		_hair.layers = _layers
		_hair.cast_shadow = _cast_shadow
		attachment.add_child(_hair)


func _skinned(node_name: StringName, mesh: Mesh, skin: Skin) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.skin = skin
	instance.layers = _layers
	instance.cast_shadow = _cast_shadow
	_skeleton.add_child(instance)
	instance.skeleton = instance.get_path_to(_skeleton)
	return instance


## Materials and per-avatar colours of the look on the shown body.
func _apply_look() -> void:
	if _mesh == null or appearance == null:
		return
	_dress(_mesh, _baked.surface_assets)
	_dress(_head, _live.head_surface_assets if _live != null else _baked.head_surface_assets)
	if _hair != null:
		_dress(_hair, [_baked.hair_asset])
	# Its hair moves past its fixed length (client side: none on a server).
	var motion: HairMotion = HairMotion.of(self)
	if motion != null:
		motion.track(self)
	# The local player's mirror double copies meshes, materials and colours: copy them again.
	var double := _skeleton.get_parent().get_node_or_null(NodePath(MirrorDouble.NODE_NAME)) as MirrorDouble
	if double != null:
		double.refresh()


## The look's materials and per-avatar colours on one of the baked meshes.
func _dress(instance: MeshInstance3D, assets: Array) -> void:
	for s in instance.mesh.get_surface_count():
		instance.set_surface_override_material(s, CharacterMaterials.human_material(assets[s], appearance, _near))
	var wrinkles: float = clampf(inverse_lerp(HumanMacros.OLD_FROM_YEARS, HumanMacros.OLD_AT_YEARS, appearance.years()), 0.0, 1.0)
	instance.set_instance_shader_parameter(&"skin_look", Vector3(appearance.skin_tone, appearance.skin_warmth, wrinkles))
	var hair: Color = appearance.hair_colour().srgb_to_linear()
	instance.set_instance_shader_parameter(&"hair_colour", Vector4(hair.r, hair.g, hair.b, 1.0))
	instance.set_instance_shader_parameter(&"hair_look", Vector4(lerpf(MIN_HAIR_KEPT, 1.0, appearance.hair_length),
			lerpf(MIN_HAIR_KEPT, 1.0, appearance.beard_length), 0.0, 0.0))
	var a: CharacterAppearance = appearance
	instance.set_instance_shader_parameter(&"skin_detail", Vector4(a.freckles, a.moles, a.wrinkles, a.redness))
	# The seed of this person's freckles and moles: their shape, so the same person keeps the same spots.
	instance.set_instance_shader_parameter(&"skin_marks", Vector4(a.eye_bags, a.unevenness, float(a.shape_hash() % 997) / 997.0,
			a.dimples))
	var eye: Color = appearance.eye_tint().srgb_to_linear()
	instance.set_instance_shader_parameter(&"eye_colour", Vector3(eye.r, eye.g, eye.b))


## The skeleton the puppet's skinned body hangs on (never a mirror's double).
func _find_skeleton() -> Skeleton3D:
	var puppet: Node = get_parent()
	if puppet == null:
		return null
	for node in puppet.find_children("*", "Skeleton3D", true, false):
		if not (node is MirrorDouble):
			return node as Skeleton3D
	return null
