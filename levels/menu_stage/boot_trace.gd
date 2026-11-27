class_name BootTrace
extends Node
## The start of the game, step by step, in godot.log while the menu gets ready, so the log of a player stuck on the
## splash says where it stopped (step) and how: the main thread frozen, or running with nothing moving on.
##
## Written with printerr, not print: an exported game writes print() to godot.log only at the next error or at a
## clean exit, so a game killed while hung lost every line after its last error, and its log said nothing
## (2026-11-27, start stuck at 1 %). printerr is written at once.
##
## A thread of its own watches the main thread (a beat each frame) and the steps: it still writes when the main
## thread is held. It reads only what step() and the beat leave under its lock, never the engine, which a hang
## could be holding. Started by the menu stage (start), off once the warm-up is done (finish) or after WATCH_FOR_S.

## A main thread without a frame for this long (s) is reported frozen.
const FROZEN_S := 5.0
## No new step for this long (s) is reported, with the step it is still on.
const STALL_S := 20.0
## A report still true is written again this often (s).
const REPEAT_S := 30.0
## The watch stops after this long (s), done or not.
const WATCH_FOR_S := 600.0
## How often the watching thread looks (ms).
const POLL_MS := 250

static var _mutex := Mutex.new()
static var _phase: String = "start"
static var _phase_ms: int = 0
static var _frame_ms: int = 0
static var _stop: bool = false

var _thread: Thread = null


## Put the trace under the tree's root, once per run; not on a server nor headless (tests).
static func start(tree: SceneTree) -> void:
	if DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server") or tree.root.has_node(^"BootTrace"):
		return
	var trace := BootTrace.new()
	trace.name = "BootTrace"
	tree.root.add_child.call_deferred(trace)


## The start is at [param what] now: written to the log, unless [param quiet] (a step too frequent to list, still
## named by the watch when nothing moves on).
static func step(what: String, quiet: bool = false) -> void:
	var now := Time.get_ticks_msec()
	_mutex.lock()
	_phase = what
	_phase_ms = now
	_mutex.unlock()
	if not quiet:
		printerr("[Boot] %6.1f s  %s" % [now / 1000.0, what])


## The step the start is on, and since when (ms since the engine started).
static func current() -> Array:
	_mutex.lock()
	var at: Array = [_phase, _phase_ms]
	_mutex.unlock()
	return at


## The last step: written, and the watch stops.
static func finish(tree: SceneTree, what: String) -> void:
	step(what)
	var trace := tree.root.get_node_or_null(^"BootTrace")
	if trace != null:
		trace.queue_free()


## Worker threads Godot runs, and how many of them take low-priority tasks (the threaded loads): the menu's world
## hung on 2 and 4 threads (WorkerThreadPool sizes itself so, threading/worker_pool/*).
static func pool_line() -> String:
	var setting: int = int(ProjectSettings.get_setting("threading/worker_pool/max_threads", -1))
	var threads: int = setting if setting > 0 else OS.get_processor_count()
	var ratio: float = float(ProjectSettings.get_setting("threading/worker_pool/low_priority_thread_ratio", 0.3))
	var low: int = clampi(int(threads * ratio), 1, maxi(threads - 1, 1))
	return "%d CPU threads, worker pool %d threads (%d for loads)" % [OS.get_processor_count(), threads, low]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1000
	_mutex.lock()
	_stop = false
	_frame_ms = Time.get_ticks_msec()
	_mutex.unlock()
	step("trace on: %s" % pool_line())
	_thread = Thread.new()
	_thread.start(_watch)


func _process(_delta: float) -> void:
	_mutex.lock()
	_frame_ms = Time.get_ticks_msec()
	_mutex.unlock()


func _exit_tree() -> void:
	_mutex.lock()
	_stop = true
	_mutex.unlock()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


## On its own thread: reports a main thread without frames, and a step that does not move on.
func _watch() -> void:
	var began := Time.get_ticks_msec()
	var frozen_reported_ms := -1
	var stall_reported_ms := -1
	var stall_of := -1
	while true:
		OS.delay_msec(POLL_MS)
		_mutex.lock()
		var stop := _stop
		var phase := _phase
		var phase_ms := _phase_ms
		var frame_ms := _frame_ms
		_mutex.unlock()
		if stop:
			return
		var now := Time.get_ticks_msec()
		if now - began > int(WATCH_FOR_S * 1000.0):
			printerr("[Boot] %6.1f s  trace off after %.0f s, still on: %s" % [now / 1000.0, WATCH_FOR_S, phase])
			return
		var frozen := (now - frame_ms) / 1000.0
		if frozen >= FROZEN_S:
			if frozen_reported_ms < 0 or now - frozen_reported_ms >= int(REPEAT_S * 1000.0):
				printerr("[Boot] %6.1f s  MAIN THREAD FROZEN for %.0f s, last step: %s" % [now / 1000.0, frozen, phase])
				frozen_reported_ms = now
		elif frozen_reported_ms >= 0:
			printerr("[Boot] %6.1f s  main thread running again" % (now / 1000.0))
			frozen_reported_ms = -1
		if phase_ms != stall_of:
			stall_of = phase_ms
			stall_reported_ms = -1
		var still := (now - phase_ms) / 1000.0
		if still >= STALL_S and (stall_reported_ms < 0 or now - stall_reported_ms >= int(REPEAT_S * 1000.0)):
			printerr("[Boot] %6.1f s  NO NEW STEP for %.0f s (main thread %s), still on: %s" % [now / 1000.0, still,
					"frozen" if frozen >= FROZEN_S else "running", phase])
			stall_reported_ms = now
