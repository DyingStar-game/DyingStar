extends GutTest
## A driver's hands on the steering wheel: the grips the vehicle measures on its wheel mesh
## (Vehicle.steering_grip_points) and how the arms take them (HandsOnWheel).

const VEHICLE := preload("res://scenes/_universe/vehicles/vehicle.gd")


## A wheel spinning about +Y: a hub of vertices near the axis and a rim ring of radius 0.12 at y = 0.01.
func _wheel() -> PackedVector3Array:
	var v := PackedVector3Array()
	for i in 32:
		var a: float = TAU * i / 32.0
		v.append(Vector3(cos(a) * 0.12, 0.01, sin(a) * 0.12))
		v.append(Vector3(cos(a) * 0.02, -0.05, sin(a) * 0.02))
	return v


func test_the_grips_sit_on_the_rim_ten_to_two() -> void:
	var grips: Array[Vector3] = VEHICLE.steering_grip_points(_wheel(), Vector3.UP, Vector3(0, 0, -1), deg_to_rad(60.0))
	assert_eq(grips.size(), 2)
	for g: Vector3 in grips:
		assert_almost_eq(Vector2(g.x, g.z).length(), 0.12, 0.001, "on the rim, not the hub")
		assert_almost_eq(g.y, 0.01, 0.001, "in the rim's plane")
		assert_almost_eq(Vector2(g.x, g.z).angle_to(Vector2(0, -1)), deg_to_rad(60.0) * signf(-g.x), 0.01,
				"60 degrees either side of the top")
	assert_almost_eq(grips[0].x, -grips[1].x, 0.001, "one each side")


func test_a_held_wheel_turns_no_further_than_the_hands_follow() -> void:
	# The truck: road wheels 30 degrees at full lock, the wheel x4 = 120, the hands follow 90.
	assert_almost_eq(VEHICLE.visual_steering_ratio(4.0, 30.0, 90.0, true), 3.0, 1e-6, "full lock = 90 degrees")
	assert_eq(VEHICLE.visual_steering_ratio(2.0, 30.0, 90.0, true), 2.0, "already within reach: unchanged")
	assert_eq(VEHICLE.visual_steering_ratio(4.0, 30.0, 90.0, false), 4.0, "nobody's hands on it: unchanged")


func test_up_along_the_axis_gives_no_grips() -> void:
	assert_true(VEHICLE.steering_grip_points(_wheel(), Vector3.UP, Vector3.UP, 1.0).is_empty(),
			"no top to measure from: no grips rather than nonsense")


func test_the_palm_faces_down_on_a_t_posed_hand_of_either_side() -> void:
	# T-pose facing +Z, palms down: the left hand reaches +X, the right -X, the thumbs forward (+Z).
	assert_almost_eq(HandsOnWheel.palm_normal(Vector3.RIGHT, Vector3.BACK, true), Vector3.DOWN, Vector3.ONE * 1e-5)
	assert_almost_eq(HandsOnWheel.palm_normal(Vector3.LEFT, Vector3.BACK, false), Vector3.DOWN, Vector3.ONE * 1e-5)


func test_a_hand_reaches_over_the_rim_and_faces_the_centre() -> void:
	# Wheel face looking +Z (away from the driver), centred on the origin, grip on the rim's left, the
	# shoulder behind and above it.
	var forearm: Vector3 = (Vector3(-0.12, 0, 0) - Vector3(-0.15, 0.3, -0.4)).normalized()
	var hold: Array[Vector3] = HandsOnWheel.hold_directions(Vector3(-0.12, 0, 0), Vector3.ZERO, Vector3.BACK, forearm)
	assert_gt(hold[0].dot(Vector3.BACK), 0.8, "the fingers reach away from the driver")
	assert_lt(hold[0].y, 0.0, "and down along the arm, the wrist in line with it")
	assert_gt(hold[1].dot(Vector3.RIGHT), 0.9, "the palm faces the centre")
	assert_almost_eq(hold[0].dot(hold[1]), 0.0, 1e-5, "square to each other")


func test_the_wheel_face_looks_away_from_the_driver() -> void:
	var grips: Array = [Vector3(-0.1, 0.05, 0.4), Vector3(0.1, 0.05, 0.4)]
	var away: Vector3 = HandsOnWheel.away_from_driver(grips, Vector3(0, -0.02, 0.4), Vector3(0, 0.3, 0))
	assert_gt(away.dot(Vector3.BACK), 0.5, "from the shoulders towards the wheel")


func test_no_lean_when_the_wheel_is_within_reach() -> void:
	var found: Array = HandsOnWheel.lean_needed(Vector3.ZERO, Vector3.RIGHT, [Vector3(0, 0.5, 0)],
			[Vector3(0, 0.4, 0.3)], [0.4], deg_to_rad(25.0))
	assert_eq(found[0], 0.0, "already in reach: upright")


func test_the_spine_leans_just_enough_to_reach() -> void:
	# Shoulder 0.5 above the pivot, wrist 0.5 ahead at shoulder height: 0.5 away, reach 0.4.
	var found: Array = HandsOnWheel.lean_needed(Vector3.ZERO, Vector3.RIGHT, [Vector3(0, 0.5, 0)],
			[Vector3(0, 0.5, 0.5)], [0.4], deg_to_rad(25.0))
	assert_gt(found[0], 0.0, "leans forward")
	assert_lt(found[0], deg_to_rad(25.0), "but not all the way")
	assert_eq(found[1], 0.0, "and reaches")


func test_out_of_reach_even_leaning_says_how_far() -> void:
	var found: Array = HandsOnWheel.lean_needed(Vector3.ZERO, Vector3.RIGHT, [Vector3(0, 0.5, 0)],
			[Vector3(0, 0.5, 2.0)], [0.4], deg_to_rad(25.0))
	assert_almost_eq(found[0], deg_to_rad(25.0), 1e-6, "leans fully")
	assert_gt(found[1], 1.0, "still well short")


func test_the_forearm_takes_the_roll_and_leaves_the_bend() -> void:
	var roll := Quaternion(Vector3.UP, 0.6)
	var bend := Quaternion(Vector3.RIGHT, 0.4)
	assert_almost_eq(HandsOnWheel.twist_about(roll, Vector3.UP).get_angle(), 0.6, 1e-4, "a pure roll: all of it")
	assert_almost_eq(HandsOnWheel.twist_about(bend, Vector3.UP).get_angle(), 0.0, 1e-4, "a pure bend: none of it")
	var both: Quaternion = bend * roll
	assert_almost_eq(HandsOnWheel.twist_about(both, Vector3.UP).get_angle(), 0.6, 0.05, "mixed: the roll")


func test_the_elbow_bends_towards_the_pole_with_both_bones_whole() -> void:
	var shoulder := Vector3.ZERO
	var wrist := Vector3(0, -0.2, 0.3)
	var elbow: Vector3 = HandsOnWheel.elbow_for(shoulder, wrist, Vector3(0, -1, -0.2), 0.25, 0.25)
	assert_almost_eq(elbow.distance_to(shoulder), 0.25, 1e-4, "upper arm kept")
	assert_almost_eq(elbow.distance_to(wrist), 0.25, 1e-4, "forearm kept")
	assert_lt(elbow.y, wrist.y, "bent down, towards the pole")


func test_out_of_reach_the_arm_is_straight() -> void:
	var elbow: Vector3 = HandsOnWheel.elbow_for(Vector3.ZERO, Vector3(0, 0, 2), Vector3.DOWN, 0.25, 0.25)
	assert_almost_eq(elbow, Vector3(0, 0, 0.25), Vector3.ONE * 1e-4, "on the line, a bone's length out")


func test_a_frame_is_the_local_transforms_multiplied_up() -> void:
	var root := Node3D.new()
	var mid := Node3D.new()
	var leaf := Node3D.new()
	root.add_child(mid)
	mid.add_child(leaf)
	root.position = Vector3(4e10, 0, 0)  # far out: must not enter the result
	mid.position = Vector3(1, 0, 0)
	mid.rotation.y = PI / 2.0
	leaf.position = Vector3(0, 0, 1)
	var xf: Transform3D = LocalFrame.of(leaf, root)
	assert_almost_eq(xf.origin, Vector3(2, 0, 0), Vector3.ONE * 1e-6, "mid's turn applied to leaf's offset")
	root.free()


func test_each_hand_takes_the_grip_on_its_side() -> void:
	var left := Vector3(0.2, 0, 0.3)
	var right := Vector3(-0.2, 0, 0.3)
	assert_eq(HandsOnWheel.by_side([right, left], 0.15, -0.15), [left, right], "swapped to match the arms")
	assert_eq(HandsOnWheel.by_side([left, right], 0.15, -0.15), [left, right], "already matching")


## A bare rig, enough for the wheel: hips, spine, and two arms of the humanoid profile's names.
func _driver() -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	var bones: Array = [["Hips", -1, Vector3.ZERO], ["Spine", 0, Vector3(0.0, 0.2, 0.0)]]
	for side: Array in [["Left", 1.0], ["Right", -1.0]]:
		var x: float = side[1]
		bones.append([side[0] + "UpperArm", 1, Vector3(0.2 * x, 0.4, 0.0)])
		bones.append([side[0] + "LowerArm", bones.size() - 1, Vector3(0.3 * x, 0.0, 0.0)])
		bones.append([side[0] + "Hand", bones.size() - 1, Vector3(0.25 * x, 0.0, 0.0)])
	for bone: Array in bones:
		var index: int = skeleton.add_bone(bone[0])
		if int(bone[1]) != -1:
			skeleton.set_bone_parent(index, bone[1])
		skeleton.set_bone_rest(index, Transform3D(Basis.IDENTITY, bone[2]))
	skeleton.reset_bone_poses()
	add_child_autofree(skeleton)
	return skeleton


## The left shoulder (skeleton's space) once the modifiers have posed the frame.
func _posed_left_shoulder(skeleton: Skeleton3D) -> Vector3:
	await skeleton.skeleton_updated
	var at: Vector3 = skeleton.get_bone_global_pose(skeleton.find_bone("LeftUpperArm")).origin
	await get_tree().process_frame  # out of the skeleton's own signal before anything frees it
	return at


## Reading the DataPad at the wheel, the device shook: it hangs on the left forearm, whose shoulder the
## lean went on moving with every twitch of the grips (the steering, the body held still on a rocking
## vehicle). The arm is off the wheel then: the spine keeps the lean it had.
func test_the_lean_holds_still_while_the_left_arm_reads_the_datapad() -> void:
	var skeleton: Skeleton3D = _driver()
	var rig: HandsOnWheel = HandsOnWheel.attach(skeleton)
	assert_not_null(rig, "the rig is built")
	var hub := Vector3(0.0, 0.5, -0.52)
	var near: Array = [hub + Vector3(0.18, 0.05, 0.0), hub + Vector3(-0.18, 0.05, 0.0)]
	var far: Array = [hub + Vector3(0.18, 0.05, -0.08), hub + Vector3(-0.18, 0.05, -0.08)]
	rig.drive(1.0, far, hub + Vector3(0.0, 0.0, -0.08))
	for _frame in 90:
		await get_tree().process_frame
	var upright: Vector3 = skeleton.get_bone_global_rest(skeleton.find_bone("LeftUpperArm")).origin
	var leaning: Vector3 = await _posed_left_shoulder(skeleton)
	assert_gt(leaning.distance_to(upright), 0.01, "out of reach: the spine leans to the wheel")
	# The grips move (the wheel pulled closer): hands on the wheel, the lean follows...
	rig.drive(1.0, near, hub)
	for _frame in 30:
		await get_tree().process_frame
	var followed: Vector3 = await _posed_left_shoulder(skeleton)
	assert_gt(followed.distance_to(leaning), 0.005, "the lean follows the wheel")
	# ...reading the DataPad, it does not.
	rig.left_released = 1.0
	for _frame in 5:
		await get_tree().process_frame
	var held: Vector3 = await _posed_left_shoulder(skeleton)
	rig.drive(1.0, far, hub + Vector3(0.0, 0.0, -0.08))
	for _frame in 30:
		await get_tree().process_frame
	var still: Vector3 = await _posed_left_shoulder(skeleton)
	assert_almost_eq(still, held, Vector3.ONE * 1e-6, "the shoulder the DataPad arm hangs from does not move")
	# The arm back on the wheel, the lean follows again.
	rig.left_released = 0.0
	for _frame in 30:
		await get_tree().process_frame
	var back: Vector3 = await _posed_left_shoulder(skeleton)
	assert_gt(back.distance_to(held), 0.005, "and follows the wheel again once the arm is back")
