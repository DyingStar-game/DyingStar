extends Node
## The VR session, when the game was launched with `--xr-mode on` (see XRMode): turns the main viewport
## into the headset's, reports what the headset can do, and follows the session (headset taken off,
## runtime asking to quit, view recentred). Without VR it does nothing.
##
## Headset-agnostic by rule: every optional feature (hand tracking, eye gaze, foveation, refresh rates) is
## asked to the runtime here, and the game falls back when it is missing.
##
## An autoload: it names no gameplay class (test_boot_light_autoloads.gd).

## The session gained or lost the user's focus: false while the headset is off the head or the
## runtime's own menu covers the game. Inputs should be ignored meanwhile.
signal focus_changed(focused: bool)
## The user recentred the view in the runtime (long press of the system button): the rig re-aligns.
signal recentered

var _xr: OpenXRInterface = null
var _focused: bool = false
## The headset's view where the game looks through a flat Camera3D (the menu's stations, any other
## scene camera): an XROrigin3D hung under that camera, with its own XRCamera3D. The player's view does
## not need it: its camera IS an XRCamera3D (VrRig).
var _follow_origin: XROrigin3D = null
var _follow_camera: XRCamera3D = null


func _ready() -> void:
	if not XRMode.is_active():
		set_process(false)
		return
	# Last of the frame and even paused: a camera the game made current this frame is followed before
	# the frame is drawn, the pause menu's included.
	process_priority = 1000
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	_xr = XRMode.interface() as OpenXRInterface
	get_viewport().use_xr = true
	XRMode.pace_by_runtime()
	_xr.session_begun.connect(_on_session_begun)
	_xr.session_focussed.connect(_on_focus.bind(true))
	_xr.session_visible.connect(_on_focus.bind(false))
	_xr.session_stopping.connect(_on_focus.bind(false))
	_xr.pose_recentered.connect(recentered.emit)
	_xr.instance_exiting.connect(_on_instance_exiting)


## Each frame, VR only: whatever flat Camera3D the game made current, the headset looks from it.
func _process(_delta: float) -> void:
	var flat: Camera3D = get_viewport().get_camera_3d()
	if flat == null or flat is XRCamera3D:
		return
	follow_flat_camera(flat)


## Hang the headset's view under [param flat]: its origin follows that camera wherever the game moves
## it, the head turns on top. The view goes back to [param flat] when it is made current again, and
## the next frame takes it over once more.
func follow_flat_camera(flat: Camera3D) -> void:
	if not is_instance_valid(_follow_origin):
		_follow_origin = XROrigin3D.new()
		_follow_origin.name = "XRFollowOrigin"
		_follow_camera = XRCamera3D.new()
		_follow_camera.name = "XRCamera"
		_follow_origin.add_child(_follow_camera)
	if _follow_origin.get_parent() != flat:
		if _follow_origin.get_parent() != null:
			_follow_origin.get_parent().remove_child(_follow_origin)
		flat.add_child(_follow_origin)
	_follow_camera.near = flat.near
	_follow_camera.far = flat.far
	_follow_camera.cull_mask = flat.cull_mask
	_follow_camera.environment = flat.environment
	_follow_camera.attributes = flat.attributes
	_follow_origin.current = true
	_follow_camera.make_current()


## True while the user is in the game (the session has the focus).
func is_focused() -> bool:
	return _focused


## Does the runtime track the fingers (optical hand tracking, or the controllers' finger sensors)?
func has_hand_tracking() -> bool:
	return _xr != null and _xr.is_hand_tracking_supported()


## Does the runtime give where the eyes look?
func has_eye_gaze() -> bool:
	return _xr != null and _xr.is_eye_gaze_interaction_supported()


## Can the runtime render the periphery at a lower resolution?
func has_foveation() -> bool:
	return _xr != null and _xr.is_foveation_supported()


## The headset's display refresh rate (Hz), 0 when unknown.
func refresh_rate() -> float:
	return _xr.display_refresh_rate if _xr != null else 0.0


func _on_session_begun() -> void:
	var info: Dictionary = _xr.get_system_info()
	print("[XR] runtime=%s %s | rate=%.0f Hz (available %s) | hand_tracking=%s eye_gaze=%s foveation=%s" % [
		info.get("XRRuntimeName", "?"), info.get("XRRuntimeVersion", ""), refresh_rate(),
		str(_xr.get_available_display_refresh_rates()), has_hand_tracking(), has_eye_gaze(),
		has_foveation()])


func _on_focus(focused: bool) -> void:
	if focused == _focused:
		return
	_focused = focused
	focus_changed.emit(focused)


## The runtime is closing (the user quit from its menu): the game quits with it.
func _on_instance_exiting() -> void:
	print("[XR] the OpenXR runtime is exiting: quitting")
	get_tree().quit()

