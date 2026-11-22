extends GutTest
## In VR the avatar's arms follow the player's hands (VrArms): the wrist where the hand is, the hand
## turned like it from its own rest geometry (whatever the bones' axes), the fingers closed like the
## tracked ones -- or by the trigger and the grip on a controller with no hand tracking.


func test_the_back_of_a_t_posed_hand_is_up_on_either_side() -> void:
	# Facing +Z, palms down: the right hand's fingers go -X, the left's +X; the index is in front.
	assert_almost_eq(VrArms.back_of_hand(Vector3.LEFT, Vector3.BACK, false), Vector3.UP, Vector3.ONE * 1e-6)
	assert_almost_eq(VrArms.back_of_hand(Vector3.RIGHT, Vector3.BACK, true), Vector3.UP, Vector3.ONE * 1e-6)


func test_the_hand_is_turned_from_its_rest_geometry() -> void:
	var rest := Basis(Vector3.UP, 0.3).scaled(Vector3.ONE * 2.0)  # bone axes anywhere, and a scale
	var turned: Basis = VrArms.turned_hand(rest, Vector3.RIGHT, Vector3.UP, Vector3.FORWARD, Vector3.RIGHT)
	var fingers: Vector3 = turned * (rest.inverse() * Vector3.RIGHT)
	assert_almost_eq(fingers.normalized(), Vector3.FORWARD, Vector3.ONE * 1e-5, "the fingers go forward")
	var back: Vector3 = turned * (rest.inverse() * Vector3.UP)
	assert_almost_eq(back.normalized(), Vector3.RIGHT, Vector3.ONE * 1e-5, "the back of the hand faces right")
	assert_almost_eq(turned.get_scale(), Vector3.ONE * 2.0, Vector3.ONE * 1e-5, "the bone's scale kept")


func test_the_fingers_bend_like_the_tracked_joints() -> void:
	var joints: Array[Vector3] = []
	for j in XRHandTracker.HAND_JOINT_MAX:
		joints.append(Vector3(0.0, 0.0, -0.02 * j))  # every finger straight along -Z...
	# ...but the index (joints 6-10) bent 90 deg at its middle joint (intermediate -> distal).
	joints[9] = joints[8] + Vector3(0.0, -0.02, 0.0)
	joints[10] = joints[9] + Vector3(0.0, -0.02, 0.0)
	var curls: Array = VrArms.finger_curls(joints)
	assert_eq(curls.size(), 4)
	assert_almost_eq(float(curls[0][1]), 90.0, 1e-3, "the index's middle joint")
	assert_almost_eq(float(curls[0][0]) + float(curls[0][2]), 0.0, 1e-3)
	assert_almost_eq(float(curls[1][0]) + float(curls[1][1]) + float(curls[1][2]), 0.0, 1e-3, "the middle: straight")


func test_without_hand_tracking_the_trigger_closes_the_index_and_the_grip_the_rest() -> void:
	var curls: Array = VrArms.pull_curls(1.0, 0.5)
	assert_eq(curls[0], VrArms.PULL_CURL_DEG, "the index, all the way")
	assert_almost_eq(float(curls[3][1]), VrArms.PULL_CURL_DEG[1] * 0.5, 1e-5, "the little finger, half way")


func test_the_wrist_goes_where_the_hand_is_and_the_fingers_point_its_way() -> void:
	var skeleton: Skeleton3D = _rig()
	var arms: Array[Dictionary] = VrArms.attach(skeleton)
	assert_eq(arms.size(), 2)
	assert_eq(skeleton.get_child(skeleton.get_child_count() - 1).name, &"VrRightHand", "last of the modifiers")
	var right: Dictionary = arms[1]
	var target := Vector3(-0.35, 0.3, 0.25)
	right["ik"].target = target
	right["ik"].pole = Vector3(-0.5, 0.0, -0.3)
	right["hand"].forward = Vector3.BACK
	right["hand"].dorsal = Vector3.UP
	for modifier: SkeletonModifier3D in [right["ik"], right["hand"]]:
		modifier.active = true
		modifier.influence = 1.0
	await skeleton.skeleton_updated
	var hand: int = skeleton.find_bone("RightHand")
	var wrist: Vector3 = skeleton.get_bone_global_pose(hand).origin
	var knuckle: Vector3 = skeleton.get_bone_global_pose(skeleton.find_bone("RightMiddleProximal")).origin
	await get_tree().process_frame  # out of the skeleton's own signal before anything frees it
	assert_almost_eq(wrist, target, Vector3.ONE * 1e-3, "the wrist on the hand")
	assert_almost_eq((knuckle - wrist).normalized(), Vector3.BACK, Vector3.ONE * 1e-3, "the fingers its way")


## A bare humanoid rig facing +Z: hips, spine, two arms with a hand and three knuckles each.
func _rig() -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	var bones: Array = [["Hips", -1, Vector3.ZERO], ["Spine", 0, Vector3(0.0, 0.2, 0.0)]]
	for side: Array in [["Left", 1.0], ["Right", -1.0]]:
		var x: float = side[1]
		bones.append([side[0] + "UpperArm", 1, Vector3(0.2 * x, 0.4, 0.0)])
		bones.append([side[0] + "LowerArm", bones.size() - 1, Vector3(0.3 * x, 0.0, 0.0)])
		bones.append([side[0] + "Hand", bones.size() - 1, Vector3(0.25 * x, 0.0, 0.0)])
		var hand: int = bones.size() - 1
		for knuckle: Array in [["Index", 0.03], ["Middle", 0.0], ["Little", -0.04]]:
			bones.append([side[0] + knuckle[0] + "Proximal", hand, Vector3(0.09 * x, 0.0, knuckle[1])])
	for bone: Array in bones:
		var index: int = skeleton.add_bone(bone[0])
		if int(bone[1]) != -1:
			skeleton.set_bone_parent(index, bone[1])
		skeleton.set_bone_rest(index, Transform3D(Basis.IDENTITY, bone[2]))
	skeleton.reset_bone_poses()
	add_child_autofree(skeleton)
	return skeleton


func test_it_hangs_on_the_game_s_puppet_with_both_hands_measured() -> void:
	var puppet: Node = (load("res://scenes/_universe/characters/humanoids/human_puppet.tscn") as PackedScene).instantiate()
	add_child_autofree(puppet)
	var skeleton: Skeleton3D = puppet.find_children("*", "Skeleton3D", true, false)[0]
	var arms: Array[Dictionary] = VrArms.attach(skeleton)
	assert_eq(arms.size(), 2, "both arms found by the humanoid profile's names")
	for arm: Dictionary in arms:
		var hand: VrArms.VrHand = arm["hand"]
		assert_true(hand._middle != -1 and hand._index != -1 and hand._little != -1, "the knuckles measured")
		assert_eq(hand._chains.size(), 4, "four fingers to close")
	puppet.queue_free()
	await get_tree().process_frame


func test_a_tracked_wrist_is_read_in_godot_s_humanoid_convention() -> void:
	# Godot turns OpenXR's joints (-Z fingers, +Y back) into its humanoid ones (+Y fingers, -Z back).
	var openxr := Basis(Vector3.UP, 0.4) * Basis(Vector3.RIGHT, -0.3)
	var godot: Basis = openxr * Basis(Quaternion(0.0, -sqrt(0.5), sqrt(0.5), 0.0))
	var hand: Dictionary = VrArms.tracked_hand(Transform3D(godot, Vector3(0.1, 0.2, 0.3)))
	assert_almost_eq(hand["forward"], openxr * Vector3.FORWARD, Vector3.ONE * 1e-5, "the fingers")
	assert_almost_eq(hand["dorsal"], openxr * Vector3.UP, Vector3.ONE * 1e-5, "the back of the hand")


func test_hands_holding_upright_controllers_face_each_other() -> void:
	# Both handles upright in front of the chest (-Z of the grip up), palms facing in.
	var right_grip := Basis(Vector3.RIGHT, Vector3.BACK, Vector3.DOWN)  # +X right, +Y towards the player
	var left_grip := Basis(Vector3.RIGHT, Vector3.BACK, Vector3.DOWN)  # +X right: out of the left palm
	var right: Dictionary = VrArms.gripped_hand(Transform3D(right_grip, Vector3.ZERO), false)
	var left: Dictionary = VrArms.gripped_hand(Transform3D(left_grip, Vector3.ZERO), true)
	assert_almost_eq(right["forward"], Vector3.FORWARD, Vector3.ONE * 1e-6, "the knuckles ahead of the wrist")
	assert_almost_eq(right["dorsal"], Vector3.RIGHT, Vector3.ONE * 1e-6, "the right hand's back faces out")
	assert_almost_eq(left["dorsal"], Vector3.LEFT, Vector3.ONE * 1e-6, "the left hand's back faces out")
	assert_almost_eq(right["wrist"], Vector3.BACK * VrArms.GRIP_TO_WRIST_M, Vector3.ONE * 1e-6, "behind the palm")
