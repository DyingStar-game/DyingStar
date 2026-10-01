class_name BenchmarkSnapshot
extends RefCounted
## Everything the benchmark changes, as it was before, and the one call that puts it all back.
##
## Nothing here is ever saved: the graphics overrides are RenderSettings' transient values, the frame
## caps go straight to Engine / DisplayServer (SettingsManager's setters would save them). So a crash
## or Alt+F4 in the middle of a run leaves settings.ini exactly as it was, and restore() may be called
## any number of times — by the runner at the end, on cancel, and again from _exit_tree as a net.

var _render : RenderSettings
var _taken : bool = false
var _max_fps : int = 0
var _vsync : int = DisplayServer.VSYNC_ENABLED
var _perf_processing : bool = false
var _atmosphere : AtmosphereRenderer = null
var _aerial_on : bool = true
var _player : Player = null
var _pitch : float = 0.0
## The yaw the benchmark turned the body by, in total: turned back by the same angle about the body's
## up, rather than restoring a basis from minutes ago (the planet has turned under it since).
var _yaw : float = 0.0
var _hidden : Array[Node] = []


func _init(render: RenderSettings) -> void:
	_render = render


## Remember the state the run is about to change. [param player] and [param atmosphere] may be null
## (tests): what they would carry is then simply not touched.
func take(player: Player, atmosphere: AtmosphereRenderer) -> void:
	_max_fps = Engine.max_fps
	_vsync = DisplayServer.window_get_vsync_mode()
	_perf_processing = ClientPerf.is_processing()
	_player = player
	if is_instance_valid(player) and player.camera_pivot != null:
		_pitch = player.camera_pivot.rotation.x
	_atmosphere = atmosphere
	if is_instance_valid(atmosphere):
		_aerial_on = atmosphere.is_aerial_enabled()
	_yaw = 0.0
	_taken = true


func max_fps() -> int:
	return _max_fps


func vsync() -> int:
	return _vsync


func aerial_on() -> bool:
	return _aerial_on


## The interface the run hid (InterfaceHider.hide_all), to be shown again by restore().
func hold_hidden(hidden: Array[Node]) -> void:
	_hidden = hidden


func add_yaw(radians: float) -> void:
	_yaw = fposmod(_yaw + radians, TAU)


## Put back everything take() recorded. Safe to call again: the second call finds nothing to do.
func restore() -> void:
	if not _taken:
		return
	_taken = false
	_render.set_transient({})
	Engine.max_fps = _max_fps
	DisplayServer.window_set_vsync_mode(_vsync as DisplayServer.VSyncMode)
	ClientPerf.set_process(_perf_processing)
	if is_instance_valid(_atmosphere):
		_atmosphere.set_aerial_enabled(_aerial_on)
	if is_instance_valid(_player) and _player.camera_pivot != null:
		if _yaw != 0.0:
			_player.global_basis = _player.global_basis.rotated(_player.global_basis.y, -_yaw)
		_player.camera_pivot.rotation.x = _pitch
	InterfaceHider.restore(_hidden)
	_hidden = []
