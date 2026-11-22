extends GutTest
## In VR the headset's camera takes the place of the player's flat camera (VrRig.install): what hung
## under the flat one (the interaction ray, the torch) hangs under it, the flat one is gone, and the
## head's pitch, yaw and offset are read relative to the body. Built without a headset: the rig's nodes
## are plain nodes until a runtime tracks them.

var _player: Node3D = null
var _ray: RayCast3D = null


func before_each() -> void:
	var fake := GDScript.new()
	fake.source_code = "extends Node3D\nvar camera_pivot: Node3D\nvar camera: Camera3D\nvar interact_label: RichTextLabel\n"
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


func test_the_headset_still_looks_from_the_player_after_a_reparent() -> void:
	var elsewhere := XROrigin3D.new()  # XRManager's own origin, for the menu
	add_child_autofree(elsewhere)
	var rig := VrRig.install(_player)
	assert_true(rig.is_current())
	var parent := _player.get_parent()
	parent.remove_child(_player)  # the server reparents the player: out of the tree...
	assert_true(elsewhere.is_current(), "Godot hands the view to another origin meanwhile")
	parent.add_child(_player)  # ...and back in
	assert_true(rig.is_current(), "the player's origin takes the view back")
	assert_false(elsewhere.is_current())


func test_the_right_hand_aims_while_it_is_tracked_and_the_head_otherwise() -> void:
	var hand := XRControllerTracker.new()
	hand.name = &"right_hand"
	hand.hand = XRPositionalTracker.TRACKER_HAND_RIGHT
	XRServer.add_tracker(hand)
	var rig := VrRig.install(_player)
	assert_eq(rig.right_aim.pose, &"aim", "aim_pose of xr/openxr_action_map.tres, as Godot names it")
	var pointer: VrPointer = rig.get_node("VrPointer")
	pointer.comfort = VrComfortSettings.new(ConfigFile.new(), func() -> void: pass)  # right-handed
	pointer.mouse_captured = func() -> bool: return true
	pointer._process(0.016)
	assert_eq(_ray.get_parent(), rig.camera, "no hand seen: the head aims, as on the flat screen")
	hand.set_pose(&"aim", Transform3D(Basis(), Vector3(0.2, -0.3, -0.2)), Vector3.ZERO, Vector3.ZERO,
			XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	pointer._process(0.016)
	assert_eq(_ray.get_parent(), rig.right_aim, "the hand seen: it aims")
	assert_eq(_ray.target_position, Vector3(0.0, 0.0, -3.0), "with the same reach")
	hand.invalidate_pose(&"aim")
	pointer._process(0.016)
	assert_eq(_ray.get_parent(), rig.camera, "the hand lost: back to the head")
	assert_false(rig.right_aim.get_node("AimDot").visible)
	XRServer.remove_tracker(hand)


func test_the_prompt_hangs_over_what_the_hand_aims_at() -> void:
	var hud_prompt := RichTextLabel.new()
	hud_prompt.bbcode_enabled = true
	hud_prompt.fit_content = true
	hud_prompt.autowrap_mode = TextServer.AUTOWRAP_OFF
	_player.add_child(hud_prompt)
	var prompt := VrPrompt.new()
	_player.add_child(prompt)
	prompt.setup(hud_prompt, _ray, _player)
	assert_eq(hud_prompt.self_modulate.a, 0.0, "the HUD's prompt is drawn clear")
	var sprite: Sprite3D = _player.get_node("VrPrompt")
	hud_prompt.text = "[X] Open"
	hud_prompt.modulate = Color.RED
	prompt._process(0.016)
	assert_true(sprite.visible)
	assert_eq(prompt._label.text, "[X] Open")
	assert_eq(prompt._label.modulate, Color.RED, "a refusal stays red")
	assert_almost_eq(sprite.global_position, _ray.global_transform * Vector3(0.0, 0.0, -VrPrompt.AHEAD_M),
			Vector3.ONE * 1e-4, "about nothing under the ray: a little ahead along it")
	hud_prompt.hide()
	prompt._process(0.016)
	assert_false(sprite.visible, "the game hides its prompt: gone")


func test_the_prompt_faces_the_eye_and_keeps_its_size_far_from_the_worlds_origin() -> void:
	# Set on the CPU in double precision: the sprite's own billboard drew it km away out here (4e10 m).
	var eye := Transform3D(Basis(), Vector3(4.0e10, 1.0e9, -2.0e10))
	var at := eye.origin + Vector3(0.6, -0.2, -2.0)
	var placed := VrPrompt.facing(at, eye)
	assert_eq(placed.origin, at)
	var to_eye: Vector3 = (eye.origin - at).normalized()
	assert_almost_eq(placed.basis.z.normalized().dot(to_eye), 1.0, 1e-6, "its face (+Z) to the eye")
	assert_almost_eq(placed.basis.get_scale().x, (eye.origin - at).length(), 1e-6,
			"twice as far, twice as big: the same size to the eye")


## A mining tool as VrTool sees it: in the hand or not, its mount and its rock ray.
class FakeTool:
	extends MiningTool
	var held: bool = true
	var mount: Node3D = null
	var ray: RayCast3D = null

	func in_hand() -> bool:
		return held

	func equipment_mount() -> Node3D:
		return mount

	func rock_ray() -> RayCast3D:
		return ray


func test_the_aiming_hand_holds_the_tool_and_aims_its_rocks() -> void:
	var hand := XRControllerTracker.new()
	hand.name = &"right_hand"
	hand.hand = XRPositionalTracker.TRACKER_HAND_RIGHT
	XRServer.add_tracker(hand)
	var rig := VrRig.install(_player)
	rig.pointer.comfort = VrComfortSettings.new(ConfigFile.new(), func() -> void: pass)  # right-handed
	rig.pointer.mouse_captured = func() -> bool: return true
	var tool := FakeTool.new()
	tool.mount = Node3D.new()
	_player.add_child(tool.mount)
	tool.ray = RayCast3D.new()
	rig.camera.add_child(tool.ray)
	rig.hold_tool(tool)
	var holder: VrTool = rig.get_node("VrTool")
	hand.set_pose(&"aim", Transform3D(Basis(Vector3.UP, 0.4), Vector3(0.25, -0.3, -0.35)), Vector3.ZERO,
			Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	rig.pointer._process(0.016)
	holder._process(0.016)
	assert_eq(tool.ray.get_parent(), rig.right_aim, "the tool mines where the hand points")
	var at := VrTool.held_at(rig.right_aim.global_transform)
	assert_almost_eq(tool.mount.global_transform.origin, at.origin, Vector3.ONE * 1e-5, "in the hand")
	tool.held = false
	var stowed := tool.mount.global_transform
	hand.set_pose(&"aim", Transform3D(Basis(), Vector3(-0.3, -0.5, -0.1)), Vector3.ZERO, Vector3.ZERO,
			XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	holder._process(0.016)
	assert_eq(tool.mount.global_transform, stowed, "stowed: the game's own pose")
	XRServer.remove_tracker(hand)
	tool.free()


func test_a_finger_on_a_screen_presses_it_and_lifting_it_lets_go() -> void:
	assert_eq(VrPointer.poke_change(false, true, 0.2), 0, "pointing from afar: no press")
	assert_eq(VrPointer.poke_change(false, true, 0.005), 1, "touching: press")
	assert_eq(VrPointer.poke_change(true, true, -0.05), 0, "through the glass: still pressed")
	assert_eq(VrPointer.poke_change(true, true, 0.02), 0, "a tremble back: still pressed")
	assert_eq(VrPointer.poke_change(true, true, 0.05), -1, "lifted: let go")
	assert_eq(VrPointer.poke_change(true, false, INF), -1, "off the screen: let go")
