extends GutTest
## Our own head is shrunk away in first person; a stand-in casts its shadow (CharacterAnimator.
## add_head_shadow): shadows only, carried by the bone above the neck, at the head's rest place.


func _rig() -> Skeleton3D:
	var sk := Skeleton3D.new()
	sk.add_bone("Spine")
	sk.add_bone("Neck")
	sk.add_bone("Head")
	sk.set_bone_parent(1, 0)
	sk.set_bone_parent(2, 1)
	sk.set_bone_rest(0, Transform3D(Basis(), Vector3(0.0, 1.3, 0.0)))
	sk.set_bone_rest(1, Transform3D(Basis(), Vector3(0.0, 0.2, 0.0)))
	sk.set_bone_rest(2, Transform3D(Basis(), Vector3(0.0, 0.1, 0.0)))
	add_child_autofree(sk)
	return sk


func test_the_head_shadow_is_shadow_only_at_the_head() -> void:
	var sk := _rig()
	var mesh: MeshInstance3D = CharacterAnimator.add_head_shadow(sk, 2, 1)
	assert_not_null(mesh)
	assert_eq(mesh.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY, "never seen, only its shadow")
	var attach := mesh.get_parent() as BoneAttachment3D
	assert_eq(attach.bone_idx, 0, "carried by the bone above the neck, which is never shrunk")
	# Head rest at y = 1.6 in the skeleton; the capsule's centre a little above it, in the carrier's frame.
	var centre_y: float = 1.3 + mesh.position.y
	assert_between(centre_y, 1.6, 1.8, "where the head stands")


func test_no_head_no_shadow() -> void:
	var sk := _rig()
	assert_null(CharacterAnimator.add_head_shadow(sk, -1, 1))
	assert_null(CharacterAnimator.add_head_shadow(sk, 2, -1))
