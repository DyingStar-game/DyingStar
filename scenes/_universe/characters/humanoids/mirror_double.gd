class_name MirrorDouble
extends Skeleton3D

## The local player's body as a mirror sees it. First person collapses our own head and neck on the
## skeleton itself (CharacterAnimator, HEAD_HIDE_SCALE), for every camera at once: in a mirror we would
## stand there headless. So a mirror gets a double -- a copy of the skeleton and of its skinned meshes,
## posed like ours every frame (the final pose, after the IKs), head and neck at their true size -- on a
## render layer of its own (Globals.RENDER_MASK_MIRROR_DOUBLE) that only the mirrors' cameras see.
##
## Made the first time a mirror comes alive near us; it only copies the pose while visible (a mirror is
## active: PlanarMirror).

const NODE_NAME := &"MirrorDouble"

var _source: Skeleton3D
var _head: int = -1
var _neck: int = -1


## The double of [param player]'s body, made beside its posed skeleton on first use; null when the
## player has no skinned body.
static func of(player: Node) -> MirrorDouble:
	var source: Skeleton3D = _posed_skeleton(player)
	if source == null:
		return null
	var existing := source.get_parent().get_node_or_null(NodePath(NODE_NAME)) as MirrorDouble
	if existing != null:
		return existing
	var double := MirrorDouble.new()
	double.name = NODE_NAME
	double._copy_from(source)
	source.get_parent().add_child(double)
	var camera := player.get("camera") as Camera3D
	if camera != null:
		camera.cull_mask &= ~Globals.RENDER_MASK_MIRROR_DOUBLE  # our own eyes never see it
	return double


## The skeleton that carries the player's skinned body (the puppet's).
static func _posed_skeleton(player: Node) -> Skeleton3D:
	for skeleton: Node in player.find_children("*", "Skeleton3D", true, false):
		if skeleton is MirrorDouble:
			continue
		for child in skeleton.get_children():
			if child is MeshInstance3D and (child as MeshInstance3D).skin != null:
				return skeleton as Skeleton3D
	return null


## Per-avatar colours of the character shaders (HumanAppearance), copied onto the double's meshes.
const INSTANCE_PARAMETERS: Array[StringName] = [&"skin_look", &"hair_colour", &"eye_colour", &"hair_look", &"skin_detail", &"skin_marks",
		&"hair_motion"]

var _faces: Array = []  # [source MeshInstance3D, copy] of the meshes with blend shapes (the face units)


## The body changed (HumanAppearance): copy the skeleton's new rests and its new meshes again.
func refresh() -> void:
	if not is_instance_valid(_source):
		return
	for child in get_children():
		if child is MeshInstance3D:
			remove_child(child)
			child.queue_free()
	for i in _source.get_bone_count():
		set_bone_rest(i, _source.get_bone_rest(i))
	motion_scale = _source.motion_scale
	_faces.clear()
	_copy_meshes()


func _copy_from(source: Skeleton3D) -> void:
	_source = source
	transform = source.transform
	for i in source.get_bone_count():
		add_bone(source.get_bone_name(i))
		set_bone_parent(i, source.get_bone_parent(i))
		set_bone_rest(i, source.get_bone_rest(i))
	motion_scale = source.motion_scale
	_head = find_bone("Head")
	_neck = find_bone("Neck")
	_copy_meshes()
	source.skeleton_updated.connect(_follow)


func _copy_meshes() -> void:
	for child in get_children():  # the hair's carrier of a previous copy
		if child is BoneAttachment3D:
			remove_child(child)
			child.queue_free()
	for child in _source.get_children():
		# Tools and the DataPad hang on bone attachments and are not in the mirror; the hair is (it hangs
		# on the Head bone, unskinned: HumanAppearance).
		if child is BoneAttachment3D and child.name == HumanAppearance.HAIR_ATTACHMENT_NAME:
			var carrier := BoneAttachment3D.new()
			add_child(carrier)
			carrier.bone_name = (child as BoneAttachment3D).bone_name
			for hair in child.get_children():
				if hair is MeshInstance3D:
					carrier.add_child(_copy_of(hair as MeshInstance3D))
			continue
		var mesh := child as MeshInstance3D
		if mesh == null or mesh.skin == null:
			continue
		var copy: MeshInstance3D = _copy_of(mesh)
		copy.skin = mesh.skin
		add_child(copy)
		copy.skeleton = copy.get_path_to(self)
		if mesh.mesh is ArrayMesh and (mesh.mesh as ArrayMesh).get_blend_shape_count() > 0:
			_faces.append([mesh, copy])


## A mesh of the body for the mirrors' cameras only: same mesh, materials and per-avatar colours.
func _copy_of(mesh: MeshInstance3D) -> MeshInstance3D:
	var copy := MeshInstance3D.new()
	copy.mesh = mesh.mesh
	copy.transform = mesh.transform
	copy.layers = Globals.RENDER_MASK_MIRROR_DOUBLE
	copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # our body already casts
	for s in mesh.get_surface_override_material_count():
		copy.set_surface_override_material(s, mesh.get_surface_override_material(s))
	for parameter in INSTANCE_PARAMETERS:
		var value: Variant = mesh.get_instance_shader_parameter(parameter)
		if value != null:
			copy.set_instance_shader_parameter(parameter, value)
	return copy


## The source's final pose of this frame, head and neck at their true size.
func _follow() -> void:
	if not visible or not is_instance_valid(_source):
		return
	for i in get_bone_count():
		set_bone_pose_position(i, _source.get_bone_pose_position(i))
		set_bone_pose_rotation(i, _source.get_bone_pose_rotation(i))
		set_bone_pose_scale(i, _source.get_bone_pose_scale(i))
	for bone: int in [_head, _neck]:
		if bone != -1:
			set_bone_pose_scale(bone, Vector3.ONE)
	# The face's expression too (face units).
	for pair: Array in _faces:
		var source: MeshInstance3D = pair[0]
		if not is_instance_valid(source):
			continue
		for k in (source.mesh as ArrayMesh).get_blend_shape_count():
			(pair[1] as MeshInstance3D).set_blend_shape_value(k, source.get_blend_shape_value(k))
