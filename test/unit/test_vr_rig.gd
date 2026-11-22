extends GutTest
## In VR the headset's camera takes the place of the player's flat camera (VrRig.install): what hung
## under the flat one (the interaction ray, the torch) hangs under it, the flat one is gone, and the
## head's pitch, yaw and offset are read relative to the body. Built without a headset: the rig's nodes
## are plain nodes until a runtime tracks them.

var _player: Node3D = null
var _ray: RayCast3D = null


func before_each() -> void:
	var fake := GDScript.new()
	fake.source_code = "extends Node3D\nvar camera_pivot: Node3D\nvar camera: Camera3D\n"
	fake.reload()
	_player = Node3D.new()
	_player.set_script(fake)
	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	pivot.position = Vector3(0.0, 1.6, -0.08)
	_player.add_child(pivot)
	var flat := Camera3D.new()
	flat.name = "Camera3D"
	flat.far = 1e13
	flat.cull_mask = 0b1011
	pivot.add_child(flat)
	_ray = RayCast3D.new()
	_ray.name = "InteractRay"
	_ray.target_position = Vector3(0.0, 0.0, -3.0)
	flat.add_child(_ray)
	_player.set("camera_pivot", pivot)
	_player.set("camera", flat)
	add_child_autofree(_player)


func after_each() -> void:
	await wait_process_frames(1)  # the flat camera install() let go is freed at the end of a frame


func test_the_headset_camera_takes_the_flat_ones_place() -> void:
	var flat: Camera3D = _player.get("camera")
	var rig := VrRig.install(_player)
	assert_eq(rig.get_parent(), _player.get("camera_pivot"), "the origin rides the camera pivot")
	assert_true(rig.current)
	assert_eq(_ray.get_parent(), rig.camera, "the interaction ray now leaves from the head")
	assert_eq(_ray.target_position, Vector3(0.0, 0.0, -3.0), "local transforms kept")
	assert_eq(rig.camera.far, XRMode.FAR_M, "not the flat 1e13: in stereo the sky goes black")
	assert_eq(rig.camera.cull_mask, 0b1011)
	assert_true(flat.is_queued_for_deletion())
	assert_null(rig.get_parent().get_node_or_null("Camera3D"))


func test_both_hands_follow_their_grip_pose() -> void:
	var rig := VrRig.install(_player)
	assert_eq(rig.left_hand.tracker, &"left_hand")
	assert_eq(rig.right_hand.tracker, &"right_hand")
	assert_eq(rig.right_hand.pose, &"grip", "grip_pose of xr/openxr_action_map.tres, as Godot names it")


func test_the_head_is_read_relative_to_the_body() -> void:
	var rig := VrRig.install(_player)
	rig.camera.transform = Transform3D(Basis.from_euler(Vector3(0.3, -0.5, 0.0)), Vector3(0.05, -0.1, 0.02))
	assert_almost_eq(rig.head_pitch(), 0.3, 1e-5, "looking up is positive, like the pivot's pitch")
	assert_almost_eq(rig.head_yaw(), -0.5, 1e-5)
	assert_almost_eq(rig.head_offset(), Vector3(0.05, -0.1, 0.02), Vector3.ONE * 1e-6)
