class_name CabScreenPointer
extends RefCounted
## The crosshair on the cab's switchable screen (RearCamera.switchable, the truck's middle one), for a
## seated player: whether it points there, the prompt naming the mode the key goes to next, and -- in the
## chart mode -- this player's own StarMap hosted on that screen and driven by the crosshair: hover, the
## mouse buttons, the wheel (taken from the limiter while the crosshair is on the chart). PlayerClient
## feeds it every frame and hands it the mouse buttons first. The mode itself is the vehicle's
## (VehicleScreenMode): the key asks the server, nothing changes here.

## How far (m) the screen can be pointed from: the cab, no further.
const REACH_M: float = 4.0
## The prompt for the mode the key switches TO.
const MODE_KEYS: Dictionary = {
	VehicleScreenMode.Mode.CAMERA: "%%HUD_CAB_SCREEN_CAMERA",
	VehicleScreenMode.Mode.MAP: "%%HUD_CAB_SCREEN_MAP",
	VehicleScreenMode.Mode.OFF: "%%HUD_CAB_SCREEN_OFF",
}

## How often (s) the one handling the chart sends its view at most, and how long after his last touch
## he still counts as the one handling it (his own view is not overwritten by an echo meanwhile).
const SEND_EVERY_S: float = 0.1
const HANDLING_S: float = 1.5

var _chart: StarMap
var _home: Control  # where the chart lives otherwise: the DataPad's NAVIGATION tab
var _send: Callable  # (action, extra) to the server: PlayerClient._send_vehicle_action
var _handling_until_ms: int = 0  # we handle the chart until then (input on it)
var _sent_at_ms: int = 0
var _sent_view: Dictionary = {}
var _shown_view: Dictionary = {}  # the shared view last shown here
var _aimed: RearCamera = null
var _at: Variant = null  # where the crosshair meets it (world), null when it does not
var _hosting: RearCamera = null  # the screen the chart is on, null when it is home
var _seen_vehicle: Node = null  # the vehicle _seen_screen was looked up for (screen_of, once per seat)
var _seen_screen: RearCamera = null


func _init(chart: StarMap, home: Control, send: Callable = Callable()) -> void:
	_chart = chart
	_home = home
	_send = send


## One frame. [param vehicle]: the one we sit in, null on foot. [param eye], [param dir]: the view's
## ray. [param chart_elsewhere]: the chart is wanted at home now (the DataPad is open), so the screen
## lets it go.
func update(vehicle: Node, eye: Vector3, dir: Vector3, chart_elsewhere: bool) -> void:
	if vehicle != _seen_vehicle or (_seen_screen != null and not is_instance_valid(_seen_screen)):
		_seen_vehicle = vehicle
		_seen_screen = screen_of(vehicle)
	var screen: RearCamera = _seen_screen
	# A dark screen (engine off, battery flat) has nothing to switch: no prompt, no F.
	_at = screen.map_gui().hit(eye, dir, REACH_M) if screen != null and screen.powered() else null
	_aimed = screen if _at != null else null
	_host(screen if screen != null and screen.wants_map() and not chart_elsewhere else null)
	if pointing_chart():
		_hosting.map_gui().pointer_at(_at)
	_share_view()


## The chart's view, shared by the cab (VehicleChartView): ours goes to the server while we handle it,
## at most every SEND_EVERY_S and only when it moved; otherwise the cab's is shown on ours.
func _share_view() -> void:
	if _hosting == null or not is_instance_valid(_hosting) or _hosting.vehicle() == null:
		return
	var now: int = Time.get_ticks_msec()
	if now < _handling_until_ms:
		if _send.is_valid() and now - _sent_at_ms >= int(SEND_EVERY_S * 1000.0):
			var view: Dictionary = VehicleChartView.clean_view(_chart.view_state())
			if view != _sent_view:
				_sent_view = view
				_sent_at_ms = now
				_send.call("vehicle_chart_view", {"view": view})
		return
	var shared: Dictionary = _hosting.vehicle().chart_view.view
	if not shared.is_empty() and shared != _shown_view:
		_shown_view = shared
		_chart.show_view(shared)


## The switchable screen of [param vehicle], null when it has none (or no vehicle).
static func screen_of(vehicle: Node) -> RearCamera:
	if vehicle == null or not vehicle.is_inside_tree():
		return null
	for node: Node in vehicle.get_tree().get_nodes_in_group(RearCamera.GROUP):
		var screen := node as RearCamera
		if screen != null and screen.vehicle() == vehicle:
			return screen
	return null


## The crosshair is on the screen: the key switches its mode.
func aimed() -> bool:
	return _aimed != null


## The prompt's text: the mode the key goes to (the action's key is the caller's to add).
func prompt_text() -> String:
	if _aimed == null:
		return ""
	return TranslationServer.translate(MODE_KEYS[VehicleScreenMode.next_of(_aimed.mode())])


## The chart is on a screen of the cab (not in the DataPad).
func hosting() -> bool:
	return _hosting != null


## The crosshair is on the chart the screen shows: the mouse buttons and the wheel are the chart's.
func pointing_chart() -> bool:
	# Not while backing up shows the feed over it: the chart is there, but not on the screen.
	return _hosting != null and _aimed == _hosting and _hosting.shows_map()


## A mouse button (the wheel included) while seated: into the chart when the crosshair is on it. True
## when it was the chart's, so nothing else takes it (the limiter's wheel, a click elsewhere).
func input(event: InputEvent) -> bool:
	var button := event as InputEventMouseButton
	if button == null or not pointing_chart():
		return false
	_hosting.map_gui().push_at(button, _at)
	_handling_until_ms = Time.get_ticks_msec() + int(HANDLING_S * 1000.0)  # we drive the shared view now
	return true


## Send the chart home now (the DataPad asks for it, or we left the seat).
func release() -> void:
	_host(null)


func _host(screen: RearCamera) -> void:
	if screen == _hosting or _chart == null:
		return
	if _hosting != null:
		if is_instance_valid(_hosting):
			_hosting.freeze_map()  # the screen keeps the chart's last image, not an empty frame
			if _hosting.tree_exiting.is_connected(release):
				_hosting.tree_exiting.disconnect(release)
		_chart.close()
		_chart.keys_live = true
		if is_instance_valid(_home):
			_chart.host_in(_home)
	_hosting = screen
	if screen != null:
		# The truck may go (deleted, out of range) with the chart on it: home first, never freed with it.
		if not screen.tree_exiting.is_connected(release):
			screen.tree_exiting.connect(release, CONNECT_ONE_SHOT)
		_chart.host_in(screen.map_slot())
		_chart.keys_live = false  # its keys and the pad are the driver's in a cab
		_chart.open()
