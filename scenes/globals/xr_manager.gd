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

## Seconds between two [XR/perf] lines in the log: frame rate, CPU and GPU time, video memory.
const PERF_LOG_S := 5.0

var _xr: OpenXRInterface = null
var _perf_wait: float = PERF_LOG_S
var _frames: int = 0
var _slowest_ms: float = 0.0
var _focused: bool = false
## The headset's view where the game looks through a flat Camera3D (the menu's stations, any other
## scene camera) or through none: an XROrigin3D placed on that camera, with its own XRCamera3D. The
## player's view does not need it: its camera IS an XRCamera3D (VrRig).
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
	# Foveated rendering: each eye's periphery is shaded coarser (Vulkan variable rate shading, from the
	# runtime's eye centres -- or the gaze, where the headset tracks it). Where the GPU has no VRS, the
	# engine renders as before.
	get_viewport().vrs_mode = Viewport.VRS_XR
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	XRMode.pace_by_runtime()
	# A late frame catches up at most MAX_PHYSICS_STEPS steps: at 8 (the default) a 80 ms frame made the
	# next one run 5 steps and come later still -- the spiral the headset's runtime timed out on.
	Engine.max_physics_steps_per_frame = XRMode.MAX_PHYSICS_STEPS
	# The HUD and the menus name the controllers' buttons, never the keys of a keyboard out of reach.
	InputDevice.hold_pad(XRMode.PAD_DEVICE)
	_build_follow_origin.call_deferred()
	var screen := XRScreen.new()  # the 2D (menus, HUD) on a panel in the headset
	screen.name = "XRScreen"
	add_child(screen)
	_xr.session_begun.connect(_on_session_begun)
	_xr.session_focussed.connect(_on_focus.bind(true))
	_xr.session_visible.connect(_on_focus.bind(false))
	_xr.session_stopping.connect(_on_focus.bind(false))
	_xr.pose_recentered.connect(recentered.emit)
	_xr.instance_exiting.connect(_on_instance_exiting)


## Each frame, VR only: whatever flat Camera3D the game made current, the headset looks from it.
func _process(delta: float) -> void:
	_measure(delta)
	var flat: Camera3D = get_viewport().get_camera_3d()
	if flat is XRCamera3D:
		return
	follow_flat_camera(flat)


## The headset looks from [param flat]: an origin of our own (never a child of the game's camera, which
## may be freed with whatever hangs under it) placed on that camera every frame, last, the head turning
## on top. The view goes back to [param flat] when the game makes it current again, and the next frame
## takes it over once more. With no camera at all (a 2D-only menu: the menu stage switched off), the
## view stands at the world's origin, the 2D panel in front of it.
func follow_flat_camera(flat: Camera3D) -> void:
	if not is_instance_valid(_follow_origin) or not _follow_origin.is_inside_tree():
		return  # built once the tree is up (_build_follow_origin)
	if flat != null:
		_follow_origin.global_transform = flat.global_transform
		_follow_camera.near = flat.near
		_follow_camera.cull_mask = flat.cull_mask
		_follow_camera.environment = flat.environment
		_follow_camera.attributes = flat.attributes
	_follow_origin.current = true
	_follow_camera.make_current()


## Our own origin and camera for follow_flat_camera, added once the tree is up (deferred from _ready:
## added during the first frame, an XROrigin3D asked for its transform before it was in).
func _build_follow_origin() -> void:
	_follow_origin = XROrigin3D.new()
	_follow_origin.name = "XRFollowOrigin"
	add_child(_follow_origin)
	_follow_camera = XRCamera3D.new()
	_follow_camera.name = "XRCamera"
	_follow_camera.far = XRMode.FAR_M
	_follow_origin.add_child(_follow_camera)


## One [XR/perf] line every PERF_LOG_S: what a headset going black or juddering needs first. The runtime
## wants a frame every 1/rate s; under it, it reprojects, then drops the app.
func _measure(delta: float) -> void:
	_frames += 1
	_slowest_ms = maxf(_slowest_ms, delta * 1000.0)
	_perf_wait -= delta
	if _perf_wait > 0.0:
		return
	var rid := get_viewport().get_viewport_rid()
	print(("[XR/perf] fps=%.0f (headset %.0f Hz) slowest=%.1fms | cpu=%.1fms gpu=%.1fms | process=%.1fms "
			+ "physics=%.1fms | vram=%.0f MiB | scale=%.2f") % [
		_frames / (PERF_LOG_S - _perf_wait), refresh_rate(), _slowest_ms,
		RenderingServer.viewport_get_measured_render_time_cpu(rid), RenderingServer.viewport_get_measured_render_time_gpu(rid),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, get_viewport().scaling_3d_scale])
	_perf_wait = PERF_LOG_S
	_frames = 0
	_slowest_ms = 0.0


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

