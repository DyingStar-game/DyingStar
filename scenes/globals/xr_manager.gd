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


func _ready() -> void:
	if not XRMode.is_active():
		return
	_xr = XRMode.interface() as OpenXRInterface
	get_viewport().use_xr = true
	XRMode.pace_by_runtime()
	_xr.session_begun.connect(_on_session_begun)
	_xr.session_focussed.connect(_on_focus.bind(true))
	_xr.session_visible.connect(_on_focus.bind(false))
	_xr.session_stopping.connect(_on_focus.bind(false))
	_xr.pose_recentered.connect(recentered.emit)
	_xr.instance_exiting.connect(_on_instance_exiting)


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

