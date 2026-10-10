class_name BenchmarkRunner
extends Node
## The in-game benchmark (Settings > Graphics > Benchmark): turns the view slowly on the spot, first
## with the player's settings, then with one costly effect turned down at a time, and writes what
## each one cost to a report the player can send. BenchmarkPlan decides the steps, BenchmarkStats
## sums up each window, BenchmarkReport writes the text; this node drives the run.
##
## While it runs, the player is a camera: the interface is hidden, the input is locked (PlayerClient
## reads `running` with the pause menu), the frame caps are lifted. Esc or B, on release, stops it;
## so does anything that takes the player out of the run (a vehicle, death, a disconnection). Either
## way BenchmarkSnapshot puts everything back, and nothing was ever saved.

enum Phase { PREPARE, WARMUP, MEASURE, DONE }

## The local player is being driven by a run. Static: PlayerClient and the Graphics page ask without
## holding the node.
static var running : bool = false

const WHY_UNAVAILABLE : String = "%%MENU_BENCH_WHY_UNAVAILABLE"
const _TOAST_HOLD_S : float = 6.0

var _phase : Phase = Phase.PREPARE
var _player : Player = null
var _atmosphere : AtmosphereRenderer = null
var _snapshot : BenchmarkSnapshot = null
var _plan : Array[Dictionary] = []
## Index in _plan of the step being warmed up or measured; -1 = the warm-up turn before the first.
var _index : int = -1
var _stats : BenchmarkStats = null
var _results : Array = []
var _header : Array = []
var _hud : BenchmarkHud = null
var _toast : ScreenToast = null
var _started_usec : int = 0
var _last_usec : int = 0
## Seconds spent in the current phase, and how long the pipeline counter has not moved.
var _phase_s : float = 0.0
var _quiet_s : float = 0.0
var _pipe_last : int = 0
var _pipe_at_measure : int = 0
## Radians turned in the current measuring window: it closes at one full turn.
var _measured_yaw : float = 0.0
var _focus_losses : int = 0
var _focus_lost : bool = false
var _cancel_armed : bool = false
var _viewports : Array[Dictionary] = []


## "" when a run can start now, else the translation key of why not (the button's tooltip). In game,
## on foot on the ground, hands free: a crate in front of the lens or a moving cabin would make two
## runs incomparable, and in a seat the camera belongs to the vehicle.
static func availability() -> String:
	if running or OS.has_feature("dedicated_server"):
		return WHY_UNAVAILABLE
	if not GameOrchestrator.current_state in [GameOrchestrator.GameStates.PLAYING, GameOrchestrator.GameStates.PAUSE_MENU]:
		return WHY_UNAVAILABLE
	var player : Player = local_player()
	if player == null or not player.is_inside_tree() or not player.active:
		return WHY_UNAVAILABLE
	if player._seat_vehicle_uuid != "" or is_instance_valid(player._seat_node):
		return WHY_UNAVAILABLE
	if player.god_mode or player.floating or player._owner_carrying or player.get_current_gravity_parent() == null:
		return WHY_UNAVAILABLE
	return ""


## Start a run, closing the pause menu first (its page is a SubViewport drawn over the game: it would
## both hide the scene and cost what it costs). Does nothing when availability() says no.
static func launch(tree: SceneTree) -> void:
	if availability() != "":
		return
	tree.call_group(&"pause_menu", &"resume")
	var runner := BenchmarkRunner.new()
	runner.name = "BenchmarkRunner"
	tree.root.add_child(runner)


## The body this client plays, or null. Untyped on the way in: player_entity dangles for a few frames
## between an old body and a new one.
static func local_player() -> Player:
	var agent : Variant = NetworkOrchestrator.network_agent
	if agent == null or not "player_entity" in agent:
		return null
	var entity : Variant = agent.player_entity
	if not is_instance_valid(entity) or not entity is Player:
		return null
	return entity as Player


func _ready() -> void:
	# After the player's own per-frame work, so the turn lands on the body's final orientation.
	process_priority = 1000
	_toast = ScreenToast.new()
	_toast.hold_seconds = _TOAST_HOLD_S
	add_child(_toast)


func _process(_delta: float) -> void:
	if _phase == Phase.DONE:
		return
	var now : int = Time.get_ticks_usec()
	var frame_ms : float = float(now - _last_usec) / 1000.0 if _last_usec > 0 else 0.0
	_last_usec = now
	if _phase == Phase.PREPARE:
		_prepare()
		return
	var why : String = _abort_reason()
	if why != "":
		cancel(why)
		return
	if _focus_lost:
		return
	var dt : float = frame_ms / 1000.0
	var yaw : float = TAU * dt / BenchmarkPlan.TURN_S
	_turn(yaw)
	if _phase == Phase.WARMUP:
		_warm_up(dt)
	else:
		_measure(frame_ms, yaw)


## Stop the run and put everything back; no report is written (the lines of the steps already
## measured are in the log). [param reason] goes to the log.
func cancel(reason: String) -> void:
	if _phase == Phase.DONE:
		return
	print("[Bench] cancelled (%s) at step %d/%d" % [reason, _index + 1, _plan.size()])
	_finish()
	_toast.show_message(tr("%%BENCH_CANCELLED"))


func _prepare() -> void:
	_player = local_player()
	if _player == null:
		_phase = Phase.DONE
		queue_free()
		return
	_atmosphere = _player.get_node_or_null("AtmosphereRenderer") as AtmosphereRenderer
	_snapshot = BenchmarkSnapshot.new(SettingsManager.render)
	_snapshot.take(_player, _atmosphere)
	_header = BenchmarkFacts.header(_player, {"max_fps": _snapshot.max_fps(), "vsync": _snapshot.vsync()})
	_snapshot.hold_hidden(InterfaceHider.hide_all(get_tree()))
	_hud = BenchmarkHud.new()
	add_child(_hud)
	running = true
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# ClientPerf's heartbeat prints several lines every 2 s through a slow logger, and its census walks
	# the whole tree: both would land in the measurement.
	ClientPerf.set_process(false)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_viewports = BenchmarkFacts.subviewports(get_tree())
	for vp in _viewports:
		vp["gpu_sum"] = 0.0
		RenderingServer.viewport_set_measure_render_time((vp["node"] as SubViewport).get_viewport_rid(), true)
	var effective : Dictionary = {}
	for option in GraphicsOptions.OPTIONS:
		effective[option["key"]] = SettingsManager.render.effective(option["key"])
	_plan = BenchmarkPlan.steps(effective, SettingsManager.render.caps.get("overridden", PackedStringArray()),
		_snapshot.aerial_on())
	_started_usec = Time.get_ticks_usec()
	_index = -1
	_enter_warmup()
	_hud.show_text(tr("%%HUD_BENCH_PREPARING"))
	print("[Bench] started: %d steps, about %d s" % [_plan.size(), roundi(BenchmarkPlan.estimate_s(_plan))])


func _turn(yaw: float) -> void:
	_player.global_basis = _player.global_basis.rotated(_player.global_basis.y, yaw)
	_player.camera_pivot.rotation.x = 0.0
	_snapshot.add_yaw(yaw)


func _enter_warmup() -> void:
	_phase = Phase.WARMUP
	_phase_s = 0.0
	_quiet_s = 0.0
	_pipe_last = PerfMath.pipeline_total()


## The first warm-up is one whole turn with the player's settings (every direction streamed and its
## pipelines compiled once); after that, each step waits until it has settled.
func _warm_up(dt: float) -> void:
	_phase_s += dt
	var pipe : int = PerfMath.pipeline_total()
	_quiet_s = _quiet_s + dt if pipe == _pipe_last else 0.0
	_pipe_last = pipe
	if _index < 0:
		if _phase_s >= BenchmarkPlan.TURN_S:
			_start_step(0)
		return
	var settled : bool = (_phase_s >= BenchmarkPlan.WARMUP_MIN_S and _quiet_s >= BenchmarkPlan.SETTLE_QUIET_S
		and _terrain_ready())
	if settled or _phase_s >= BenchmarkPlan.WARMUP_MAX_S:
		_begin_measure(settled)


func _start_step(index: int) -> void:
	_index = index
	var step : Dictionary = _plan[index]
	SettingsManager.render.set_transient(step["set"])
	if is_instance_valid(_atmosphere):
		_atmosphere.set_aerial_enabled(step["aerial"])
	_hud.show_text(tr("%%HUD_BENCH_PROGRESS") % [index + 1, _plan.size(), _step_text(step)])
	# The previous step's line, printed now: the logger's cost lands in a warm-up, never in a window.
	if not _results.is_empty():
		print("[Bench] %s" % BenchmarkReport.step_line(_results.back(), _results[0]["window"]))
	_enter_warmup()


func _begin_measure(settled: bool) -> void:
	_phase = Phase.MEASURE
	_stats = BenchmarkStats.new()
	_stats.finish({"settle_s": _phase_s, "settled": settled})
	_measured_yaw = 0.0
	_pipe_at_measure = PerfMath.pipeline_total()


func _measure(frame_ms: float, yaw: float) -> void:
	var root_rid : RID = get_viewport().get_viewport_rid()
	_stats.add_frame(frame_ms, {
		"gpu": RenderingServer.viewport_get_measured_render_time_gpu(root_rid),
		"cpu": RenderingServer.viewport_get_measured_render_time_cpu(root_rid),
		"setup": RenderingServer.get_frame_setup_time_cpu(),
		"proc": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"phys": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
	})
	if _plan[_index]["id"] == BenchmarkPlan.BASELINE:
		for vp in _viewports:
			if is_instance_valid(vp["node"]):
				vp["gpu_sum"] += RenderingServer.viewport_get_measured_render_time_gpu(
					(vp["node"] as SubViewport).get_viewport_rid())
	_measured_yaw += yaw
	if _measured_yaw < TAU:
		return
	var window : Dictionary = _stats.summary()
	window.merge({
		"draws": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"objects": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		"primitives": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		"vram_mib": BenchmarkFacts.vram_mib(),
		"pipe": PerfMath.pipeline_total() - _pipe_at_measure,
	}, true)
	if _plan[_index]["id"] == BenchmarkPlan.BASELINE:
		for vp in _viewports:
			vp["gpu"] = vp["gpu_sum"] / maxf(float(window["frames"]), 1.0)
	_results.append({"id": _plan[_index]["id"], "set": _plan[_index]["set"], "window": window})
	if _index + 1 < _plan.size():
		_start_step(_index + 1)
	else:
		_complete()


func _complete() -> void:
	var duration_s : int = roundi(float(Time.get_ticks_usec() - _started_usec) / 1000000.0)
	_finish()
	var text : String = BenchmarkReport.format({
		"status": "complete",
		"header": _header,
		"run": {"turn_s": BenchmarkPlan.TURN_S, "warmup_min_s": BenchmarkPlan.WARMUP_MIN_S,
			"duration_s": duration_s, "focus_losses": _focus_losses},
		"results": _results,
		"subviewports": _viewports,
	})
	var path : String = CapturePaths.benchmarks_dir().path_join("benchmark_%s.txt" % CapturePaths.stamp())
	var file : FileAccess = FileAccess.open(path, FileAccess.WRITE)
	print("[Bench] report:\n%s" % text)
	if file == null:
		push_warning("Benchmark: cannot write %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		_toast.show_message(tr("%%BENCH_FAILED") % path)
		return
	file.store_string(text)
	file.close()
	DisplayServer.clipboard_set(text)
	_toast.show_message(tr("%%BENCH_SAVED") % path)


## Everything back as it was, then leave once the toast has faded.
func _finish() -> void:
	_phase = Phase.DONE
	if _snapshot != null:
		_snapshot.restore()
	for vp in _viewports:
		if is_instance_valid(vp["node"]):
			RenderingServer.viewport_set_measure_render_time((vp["node"] as SubViewport).get_viewport_rid(), false)
	running = false
	if is_instance_valid(_hud):
		_hud.queue_free()
	get_tree().create_timer(_TOAST_HOLD_S + _toast.fade_seconds + 0.5).timeout.connect(queue_free)


func _abort_reason() -> String:
	if not is_instance_valid(_player) or not _player.is_inside_tree():
		return "player_lost"
	if GameOrchestrator.current_state != GameOrchestrator.GameStates.PLAYING:
		return "state_changed"
	if _player._seat_vehicle_uuid != "" or is_instance_valid(_player._seat_node):
		return "seated"
	return ""


## The ground has caught up with the last change: the chunks the LOD pass asked for are built.
func _terrain_ready() -> bool:
	var planet : Planet = Planet.of(_player)
	if planet == null or planet.planet_terrain == null or planet.planet_terrain.desired_chunk_count() <= 0:
		return true
	var built : float = float(planet.planet_terrain.active_chunk_count()) / planet.planet_terrain.desired_chunk_count()
	return built >= BenchmarkPlan.TERRAIN_READY


## What a step changes, in the player's language: "Shadows → Off".
func _step_text(step: Dictionary) -> String:
	match step["id"]:
		BenchmarkPlan.BASELINE:
			return tr("%%HUD_BENCH_STEP_BASELINE")
		BenchmarkPlan.BASELINE_END:
			return tr("%%HUD_BENCH_STEP_BASELINE_END")
		BenchmarkPlan.AERIAL:
			return tr("%%HUD_BENCH_STEP_AERIAL")
	var key : String = step["set"].keys()[0]
	var option : Dictionary = GraphicsOptions.find(key)
	return "%s → %s" % [tr(option["label"]), tr(GraphicsOptions.value_text(option, step["set"][key]))]


## Esc or B stops the run when it comes back UP: stopped on the press, the game would wake with B
## still down, and B is crouch. Every other key, button and stick is swallowed — the player is a
## camera until the run ends.
func _input(event: InputEvent) -> void:
	if _phase == Phase.DONE or _phase == Phase.PREPARE:
		return
	if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		_cancel_armed = true
	elif _cancel_armed and (event.is_action_released("pause") or event.is_action_released("ui_cancel")):
		_cancel_armed = false
		get_viewport().set_input_as_handled()
		cancel("player")
		return
	get_viewport().set_input_as_handled()


## A window in the background is throttled by the OS and the driver: its frames say nothing. The
## step being measured is dropped and warmed up again once the window is back.
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			if _phase == Phase.WARMUP or _phase == Phase.MEASURE:
				_focus_lost = true
		NOTIFICATION_APPLICATION_FOCUS_IN:
			if _focus_lost:
				_focus_lost = false
				_focus_losses += 1
				_last_usec = 0
				_enter_warmup()
		NOTIFICATION_WM_CLOSE_REQUEST:
			if _snapshot != null:
				_snapshot.restore()


func _exit_tree() -> void:
	if _snapshot != null:
		_snapshot.restore()
	running = false
