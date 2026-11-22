extends GutTest
## A baked body on the puppet's skeleton (HumanAppearance): the animation library stays valid -- every
## rest ROTATION is the template's, and although the body is modelled in an A pose the skeleton rests in
## the template's T pose (each bone points where the template's does) -- the binds carry the mesh there,
## the soles stand on y = 0, and motion_scale is the new hips height.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_human_appearance.gd -gexit

const PUPPET := "res://scenes/_universe/characters/humanoids/human_puppet.tscn"


func before_all() -> void:
	HumanBuilder.generate_lods = false  # most of a bake's time, and not what is tested here


func after_all() -> void:
	HumanBuilder.generate_lods = true


func _puppet() -> Node3D:
	var puppet: Node3D = (load(PUPPET) as PackedScene).instantiate()
	add_child_autofree(puppet)
	return puppet


func _skeleton(puppet: Node) -> Skeleton3D:
	return puppet.get_node("Body/Armature/GeneralSkeleton") as Skeleton3D


func _dressed(seed_value: int) -> Array:
	var puppet: Node3D = _puppet()
	var looks: HumanAppearance = puppet.get_node("HumanAppearance")
	looks.set_appearance_now(CharacterAppearance.random(seed_value))
	return [looks, _skeleton(puppet)]


func test_rest_rotations_are_kept_and_the_joints_move() -> void:
	var template: Skeleton3D = _skeleton(_puppet())
	var pair: Array = _dressed(17)
	var skeleton: Skeleton3D = pair[1]
	assert_true((pair[0] as HumanAppearance).is_applied())
	var moved: int = 0
	for i in skeleton.get_bone_count():
		assert_true(template.get_bone_global_rest(i).basis.is_equal_approx(skeleton.get_bone_global_rest(i).basis),
				"%s keeps its rest rotation" % skeleton.get_bone_name(i))
		if template.get_bone_global_rest(i).origin.distance_to(skeleton.get_bone_global_rest(i).origin) > 0.005:
			moved += 1
	assert_gt(moved, 20, "another body: the joints moved")


func test_the_skeleton_rests_in_the_templates_pose() -> void:
	# The body is modelled arms down at 45 degrees; the skeleton must rest arms out, as the template.
	var template: Skeleton3D = _skeleton(_puppet())
	var skeleton: Skeleton3D = _dressed(23)[1]
	for pair: Array in [["LeftUpperArm", "LeftLowerArm"], ["RightLowerArm", "RightHand"], ["LeftUpperLeg", "LeftLowerLeg"],
			["RightIndexProximal", "RightIndexIntermediate"]]:
		var a: int = skeleton.find_bone(pair[0])
		var b: int = skeleton.find_bone(pair[1])
		var mine: Vector3 = (skeleton.get_bone_global_rest(b).origin - skeleton.get_bone_global_rest(a).origin).normalized()
		var theirs: Vector3 = (template.get_bone_global_rest(b).origin - template.get_bone_global_rest(a).origin).normalized()
		assert_gt(mine.dot(theirs), 0.9999, "%s points where the template's does" % pair[0])


func test_the_trunk_keeps_its_own_curve() -> void:
	# A straightened spine broke the back: each segment turned as a block. Trunk binds never turn the mesh.
	var looks: HumanAppearance = _dressed(23)[0]
	var skeleton: Skeleton3D = looks.body_mesh().get_parent()
	var skin: Skin = looks.body_mesh().skin
	for i in skin.get_bind_count():
		var bone: StringName = skin.get_bind_name(i)
		if HumanBuilder.TRUNK_BONES.has(bone):
			var at_rest: Basis = (skeleton.get_bone_global_rest(skeleton.find_bone(bone)) * skin.get_bind_pose(i)).basis
			assert_true(at_rest.is_equal_approx(Basis.IDENTITY), "%s leaves the mesh as modelled" % bone)


func test_binds_carry_the_mesh_and_the_body_stands_on_the_ground() -> void:
	var pair: Array = _dressed(29)
	var looks: HumanAppearance = pair[0]
	var skeleton: Skeleton3D = pair[1]
	var body: MeshInstance3D = looks.body_mesh()
	assert_not_null(body)
	assert_eq(body.get_parent(), skeleton, "the baked body hangs on the puppet's skeleton")
	var lowest: float = INF
	for i in body.skin.get_bind_count():
		var bone: int = skeleton.find_bone(body.skin.get_bind_name(i))
		assert_ne(bone, -1)
		var at_rest: Transform3D = skeleton.get_bone_global_rest(bone) * body.skin.get_bind_pose(i)
		assert_almost_eq(at_rest.basis.determinant(), 1.0, 1e-4, "%s: the bind turns, never stretches" % body.skin.get_bind_name(i))
		lowest = minf(lowest, skeleton.get_bone_global_rest(bone).origin.y)
	assert_between(lowest, -0.001, 0.05, "the lowest joint is at the soles, on the ground")
	var hips: float = skeleton.get_bone_global_rest(skeleton.find_bone("Hips")).origin.y
	assert_almost_eq(skeleton.motion_scale, hips, 1e-5, "motion_scale = hips height")
	assert_between(hips, 0.7, 1.1)
	var imported: int = 0
	for child in skeleton.get_children():
		if child is MeshInstance3D and child != body and child != looks.head_mesh() and not child.is_queued_for_deletion():
			imported += 1
	assert_eq(imported, 0, "the imported meshes are gone")
	assert_gte(body.mesh.get_surface_count(), 1, "the body's zones, plus the hair and the clothes")
	var head: MeshInstance3D = looks.head_mesh()
	assert_not_null(head, "the head is a mesh of its own")
	assert_eq(head.get_parent(), skeleton)
	assert_same(head.skin, body.skin, "on the same binds")
	assert_gt(head.mesh.get_surface_count(), 4, "face, eyes, mouth: one surface per zone")
	assert_eq((head.mesh as ArrayMesh).get_blend_shape_count(), 0, "a plain head carries no blend shape")


func test_height_scales_the_whole_body() -> void:
	var short: CharacterAppearance = CharacterAppearance.preset("default_male")
	var tall: CharacterAppearance = short.duplicate_appearance()
	short.macros["height"] = 0.0
	tall.macros["height"] = 1.0
	var a: HumanBuilder.Baked = HumanMeshCache.build_now(short, false)
	var b: HumanBuilder.Baked = HumanMeshCache.build_now(tall, false)
	assert_almost_eq(b.hips_height / a.hips_height, HumanMacros.MAX_STATURE / HumanMacros.MIN_STATURE, 0.01)


func test_colour_change_keeps_the_mesh() -> void:
	var looks: HumanAppearance = _puppet().get_node("HumanAppearance")
	var a: CharacterAppearance = CharacterAppearance.random(31)
	looks.set_appearance_now(a)
	var mesh: Mesh = looks.body_mesh().mesh
	var b: CharacterAppearance = a.duplicate_appearance()
	b.hair_grey = 1.0
	b.skin_tone = 0.9
	looks.set_appearance(b)
	assert_same(looks.body_mesh().mesh, mesh, "same shape: no new bake, no new mesh")
	var look: Vector3 = looks.body_mesh().get_instance_shader_parameter(&"skin_look")
	assert_almost_eq(look.x, b.skin_tone, 1e-6, "the skin tone is a per-avatar value")


func test_animator_follows_the_new_rests() -> void:
	# A rig measured on the imported character must be measured again on the new body.
	var puppet: Node3D = _puppet()
	var skeleton: Skeleton3D = _skeleton(puppet)
	var rig: HandsOnWheel = HandsOnWheel.attach(skeleton)
	var before: float = rig._arms[0].length
	var a: CharacterAppearance = CharacterAppearance.random(2)
	a.macros["height"] = 1.0
	(puppet.get_node("HumanAppearance") as HumanAppearance).set_appearance_now(a)
	rig.remeasure(skeleton)
	assert_ne(rig._arms[0].length, before, "the arm length follows the body")
	var expected: float = skeleton.get_bone_global_rest(rig._arms[0].upper).origin.distance_to(
			skeleton.get_bone_global_rest(rig._arms[0].lower).origin) \
			+ skeleton.get_bone_global_rest(rig._arms[0].lower).origin.distance_to(
			skeleton.get_bone_global_rest(rig._arms[0].hand).origin)
	assert_almost_eq(rig._arms[0].length, expected, 1e-6)


func test_hair_goes_on_the_body_and_brows_on_the_head() -> void:
	var look: CharacterAppearance = CharacterAppearance.random(61)
	look.hair = 2  # a style with a scalp shell and hair
	look.cut = look.style_cut(2)
	look.eyebrows = 0
	var baked: HumanBuilder.Baked = HumanMeshCache.build_now(look, false)
	var shells: int = 0
	for s in baked.surface_assets.size():
		if not (baked.surface_assets[s] is HumanAssetData):
			continue
		var asset: HumanAssetData = baked.surface_assets[s]
		if asset.kind == &"hair":
			shells += 1
			assert_true(asset.style in [&"shell", &"scalp"], "on the body's mesh, only the scalp's shell or shade")
			assert_eq(asset.color.size(), asset.vertex.size(), "hair carries a colour per vertex, for its shader")
			assert_not_null(baked.mesh.surface_get_arrays(s)[Mesh.ARRAY_COLOR])
			assert_true(CharacterMaterials.human_material(asset, look) is ShaderMaterial)
	assert_gt(shells, 0)
	# The hair itself is a mesh of its own, shared by everyone who wears the style, on the head bone.
	assert_not_null(baked.hair_mesh)
	assert_eq(baked.hair_asset.style, &"strands")
	assert_same(baked.hair_mesh, HairStrands.mesh_of(baked.hair_asset), "one mesh per cut")
	var other: CharacterAppearance = CharacterAppearance.random(62)
	other.hair = 2
	other.cut = other.style_cut(2)
	assert_same(HumanMeshCache.build_now(other, false).hair_mesh, baked.hair_mesh, "another head, the same cut: the same hair mesh")
	var puppet: Node3D = _puppet()
	var looks: HumanAppearance = puppet.get_node("HumanAppearance")
	looks.set_appearance_now(look)
	var hair: MeshInstance3D = looks.hair_mesh()
	assert_not_null(hair)
	assert_true(hair.get_parent() is BoneAttachment3D, "unskinned, carried by the head bone")
	assert_eq((hair.get_parent() as BoneAttachment3D).bone_name, "Head")
	assert_true(hair.get_surface_override_material(0) is ShaderMaterial)
	look.hair = 0
	looks.set_appearance_now(look)
	assert_null(looks.hair_mesh(), "bald: no hair, and no carrier left behind")
	assert_null(_skeleton(puppet).get_node_or_null(NodePath(HumanAppearance.HAIR_ATTACHMENT_NAME)))
	look.hair = 2
	baked = HumanMeshCache.build_now(look, false)
	var on_head: Array = []
	for what: Variant in baked.head_surface_assets:
		if what is HumanAssetData:
			on_head.append((what as HumanAssetData).kind)
	assert_true(on_head.has(&"eyebrows") and on_head.has(&"eyelashes"), "what grows on the face is the head's")
	# ... so that a live head moves it with the face: a blink carries the lashes.
	var live: HumanBuilder.Baked = HumanMeshCache.build_now(look, false, true)
	var lashes: int = -1
	for s in live.head_surface_assets.size():
		if live.head_surface_assets[s] is HumanAssetData and (live.head_surface_assets[s] as HumanAssetData).kind == &"eyelashes":
			lashes = s
	assert_ne(lashes, -1)
	var at_rest: PackedVector3Array = live.head_mesh.surface_get_arrays(lashes)[Mesh.ARRAY_VERTEX]
	var blink: PackedVector3Array = live.head_mesh.surface_get_blend_shape_arrays(lashes)[0][Mesh.ARRAY_VERTEX]
	var moved: float = 0.0
	for i in at_rest.size():
		moved = maxf(moved, at_rest[i].distance_to(blink[i]))
	assert_gt(moved, 0.003, "the lashes come down with the lid")
