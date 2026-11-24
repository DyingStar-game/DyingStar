extends GutTest
## In VR the body is kept under the head (VrBody): it turns to the gaze -- at once while the stick walks,
## past a leeway standing still -- and walks under a step taken in the room, the view never moving for
## it. Played on a rig without a headset: the head is the XRCamera3D's transform, set by hand.

var _player: Node3D = null
var _rig: VrRig = null
var _body: VrBody = null
var _comfort: VrComfortSettings = null


func before_each() -> void:
	var fake := GDScript.new()
	fake.source_code = ("extends Node3D\nvar camera_pivot: Node3D\nvar camera: Camera3D\n"
			+ "var mouse_motion := Vector2.ZERO\nvar camera_sensitivity := 0.002\n")
	fake.reload()
	_player = Node3D.new()
	_player.set_script(fake)
	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	pivot.position = Vector3(0.0, 1.6, -0.08)
	_player.add_child(pivot)
	var flat := Camera3D.new()
	pivot.add_child(flat)
	_player.set("camera_pivot", pivot)
	_player.set("camera", flat)
	add_child_autofree(_player)
	_player.rotate_object_local(Vector3.UP, 0.7)  # facing anywhere
	_rig = VrRig.install(_player)
	_body = _rig.body
	_comfort = VrComfortSettings.new(ConfigFile.new(), func() -> void: pass)  # the defaults, not the player's
	_body.comfort = _comfort
	_body.on_foot = func() -> bool: return true
	_body.seated = func() -> bool: return false


func after_each() -> void:
	await wait_process_frames(1)


func _head(yaw_deg: float, at: Vector3 = Vector3.ZERO) -> void:
	_rig.camera.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), at)


func _same(a: Transform3D, b: Transform3D, why: String) -> void:
	assert_almost_eq(a.origin, b.origin, Vector3.ONE * 1e-4, why + " (place)")
	for i in 3:
		assert_almost_eq(a.basis[i], b.basis[i], Vector3.ONE * 1e-4, why + " (turn)")


func test_turning_the_body_leaves_the_head_where_it_is() -> void:
	_head(30.0, Vector3(0.1, 0.05, -0.2))
	var seen := _rig.camera.global_transform
	_body.turn_body(deg_to_rad(30.0))
	_same(_rig.camera.global_transform, seen, "the view does not move")
	assert_almost_eq(_rig.head_yaw(), 0.0, 1e-5, "the body now faces the gaze")


func test_walking_with_the_stick_faces_the_gaze() -> void:
	_head(40.0)
	_body.stick = Vector2(0.0, 1.0)
	_body._process(0.016)
	assert_almost_eq(_rig.head_yaw(), 0.0, 1e-5, "forward is where the head looks")


func test_standing_the_head_looks_around_freely_then_the_body_follows() -> void:
	_head(40.0)
	_body._process(0.016)
	assert_almost_eq(_rig.head_yaw(), deg_to_rad(40.0), 1e-5, "40 deg: the body stays")
	_head(-80.0)
	_body._process(0.016)
	assert_almost_eq(_rig.head_yaw(), -VrBody.HEAD_FREE_YAW, 1e-5, "80 deg: it comes as far as the leeway")


func test_a_step_in_the_room_walks_the_body_under_the_head_and_the_view_stays() -> void:
	_head(0.0, Vector3(0.0, 0.0, -0.4))  # the player stepped 40 cm forward
	_body._process(0.016)
	assert_gt(_body.chase.y, 0.5, "the body walks forward, under the head")
	assert_almost_eq(_body.chase.x, 0.0, 1e-5)
	var seen := _rig.camera.global_transform
	_player.translate_object_local(Vector3(0.0, 0.0, -0.3))  # the server moved it 30 cm
	_body._process(0.016)
	_same(_rig.camera.global_transform, seen, "the body caught up, the view did not slide")
	_player.translate_object_local(Vector3(0.0, 0.0, -0.06))
	_body._process(0.016)
	assert_eq(_body.chase, Vector2.ZERO, "under the head: it stops")


func test_the_stick_walking_moves_the_view_with_the_body() -> void:
	_head(0.0)
	_body.stick = Vector2(0.0, 1.0)
	_body._process(0.016)
	var seen := _rig.camera.global_position
	_player.translate_object_local(Vector3(0.0, 0.0, -0.5))
	_body._process(0.016)
	assert_almost_eq(_rig.camera.global_position.distance_to(seen), 0.5, 1e-4, "walked: the view goes along")


func test_recentring_puts_the_head_over_the_body_looking_along_it() -> void:
	_head(70.0, Vector3(0.3, 0.1, 0.2))
	var height: float = _rig.head_offset().y
	_body.recenter(true)
	assert_almost_eq(_rig.head_yaw(), 0.0, 1e-5)
	assert_almost_eq(_rig.head_offset(), Vector3(0.0, height, 0.0), Vector3.ONE * 1e-4)


func test_the_catch_up_push_is_never_under_the_sticks_deadzone() -> void:
	var push := VrBody.catch_up(Vector2(-0.1, 0.0))
	assert_almost_eq(push.length(), VrBody.CHASE_MIN, 1e-5)
	assert_lt(push.x, 0.0, "a head to the left: walk left")
	assert_almost_eq(VrBody.catch_up(Vector2(0.0, 2.0)), Vector2(0.0, -1.0), Vector2.ONE * 1e-5,
			"a head far behind: walk back at full push")


func test_playing_seated_a_lean_is_not_a_step() -> void:
	_comfort.set_value("seated", true)
	_head(0.0, Vector3(0.0, 0.0, -0.4))
	_body._process(0.016)
	assert_eq(_body.chase, Vector2.ZERO)


func test_the_walking_hand_can_steer_the_walk() -> void:
	_comfort.set_value("walk", VrComfortSettings.WALK_HAND)
	var hand := XRControllerTracker.new()
	hand.name = &"left_hand"
	hand.hand = XRPositionalTracker.TRACKER_HAND_LEFT
	XRServer.add_tracker(hand)
	await wait_process_frames(1)  # the aim node binds to the new tracker
	hand.set_pose(&"aim", Transform3D(Basis(Vector3.UP, deg_to_rad(-60.0)), Vector3.ZERO), Vector3.ZERO,
			Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	_head(20.0)
	_body.stick = Vector2(0.0, 1.0)
	_body._process(0.016)
	assert_almost_eq(VrBody.pointing_yaw(_rig.basis * _rig.left_aim.basis), 0.0, 1e-4,
			"the body faces where the left hand points, not the head")
	XRServer.remove_tracker(hand)


func test_the_edges_darken_by_the_motion() -> void:
	assert_eq(VrVignette.target(0.0, 0.0), 0.0, "still: clear")
	assert_almost_eq(VrVignette.target(1.0, 0.0), VrVignette.WALKING, 1e-6)
	assert_almost_eq(VrVignette.target(0.3, 1.0), VrVignette.TURNING, 1e-6, "turning darkens most")
