class_name VrRig
extends XROrigin3D
## The owner's view in VR (`--xr-mode on`, see XRMode): an XROrigin3D on the camera pivot, whose
## XRCamera3D TAKES THE PLACE of the flat Camera3D. The flat camera's children (the interaction ray, the
## torch...) move under it and `player.camera` becomes it, so everything that looks through, aims from
## or keeps `player.camera` current goes on working, now from the head. Built by Player._ready, before
## anything holds on to the camera; never on a remote avatar, never on the server.
##
## The origin sits on the camera pivot, which the head camera (HeadCam) drives to the eye of the posture:
## the reference space is LOCAL (project setting xr/openxr/reference_space), whose zero is where the
## headset was at the start, so the eye lands on the pivot whatever the player's height, seated or
## standing, and crouching for real lowers the view from there. The pivot's own pitch and seated yaw are
## the mouse's and stay at zero in VR: the head gives them (PlayerClient).
##
## Everything here is local to the pivot: the world is some 4e10 m out, and only local transforms keep
## the view from shaking (see HandsOnWheel).

## The headset's camera; `player.camera` from install() on.
var camera: XRCamera3D = null
## The hands' grip poses (where the palm holds), left and right. Their trackers exist only while the
## runtime sees the controller (or the hand).
var left_hand: XRController3D = null
var right_hand: XRController3D = null
## Where the right hand points (its aim pose): the interaction ray leaves from it (VrPointer).
var right_aim: XRController3D = null


## Put the VR view on [param player] (a Player): returns the rig, whose camera replaces the flat one.
static func install(player: Node3D) -> VrRig:
	var pivot: Node3D = player.get("camera_pivot")
	var flat: Camera3D = player.get("camera")
	var rig := VrRig.new()
	rig.name = "VrRig"
	pivot.add_child(rig)
	rig.current = true
	rig.camera = _camera_like(flat)
	rig.add_child(rig.camera)
	for child: Node in flat.get_children():
		child.reparent(rig.camera, false)
	pivot.remove_child(flat)
	flat.queue_free()
	rig.left_hand = _hand(&"left_hand", "LeftHand")
	rig.add_child(rig.left_hand)
	rig.right_hand = _hand(&"right_hand", "RightHand")
	rig.add_child(rig.right_hand)
	rig.right_aim = _hand(&"right_hand", "RightAim")
	rig.right_aim.pose = &"aim"
	rig.add_child(rig.right_aim)
	# The right hand aims: the interaction ray leaves from it, a dot where it meets something.
	var ray := rig.camera.get_node_or_null("InteractRay") as RayCast3D
	if ray != null:
		var pointer := VrPointer.new()
		pointer.name = "VrPointer"
		pointer.setup(ray, rig.right_aim, rig.camera)
		rig.add_child(pointer)
	# The controllers played as a gamepad: every gamepad binding of the game works from them.
	var controls := VrInput.new()
	controls.name = "VrInput"
	controls.setup(player, rig.left_hand, rig.right_hand)
	rig.add_child(controls)
	# The controllers as the runtime draws them (OpenXR render models): any headset's, none to model.
	# Only with a live OpenXR session: without one the manager finds no extension and errors each frame
	# (with one, a runtime lacking render models leaves it idle).
	if XRMode.is_active():
		var models := OpenXRRenderModelManager.new()
		models.name = "ControllerModels"
		rig.add_child(models)
	return rig


## Back in the tree, the headset looks from here again. The server reparents the player (building ->
## planet -> vehicle), which takes it out of the tree and back; Godot drops `current` from an origin
## leaving the tree and hands it to another one -- XRManager's, at the world's origin, 4e10 m from the
## planet -- and never gives it back: the headset went black as the player stepped outside (2026-11-22).
func _enter_tree() -> void:
	current = true


## The head's pitch (rad) relative to the body: up is positive, like the camera pivot's.
func head_pitch() -> float:
	return camera.transform.basis.get_euler().x


## The head's yaw (rad) relative to the body: left is positive, like the camera pivot's.
func head_yaw() -> float:
	return camera.transform.basis.get_euler().y


## Where the eye is in the pivot's space (m): the headset's offset from where it started.
func head_offset() -> Vector3:
	return transform * camera.position


static func _camera_like(flat: Camera3D) -> XRCamera3D:
	var cam := XRCamera3D.new()
	cam.name = "XRCamera"
	cam.near = flat.near
	cam.far = XRMode.FAR_M  # not the flat camera's 1e13: see XRMode.FAR_M
	cam.cull_mask = flat.cull_mask
	cam.environment = flat.environment
	cam.attributes = flat.attributes
	cam.compositor = flat.compositor
	cam.doppler_tracking = flat.doppler_tracking
	return cam


static func _hand(tracker: StringName, node_name: String) -> XRController3D:
	var hand := XRController3D.new()
	hand.name = node_name
	hand.tracker = tracker
	hand.pose = &"grip"  # the grip_pose action: Godot drops the "_pose" on the tracker
	return hand
