extends Node
## Client-side performance heartbeat — the thing the 5 FPS reports kept lacking.
##
## Three player logs of the "5-6 FPS on preprod" bug turned out to be INDISTINGUISHABLE from a
## healthy client's log: same 3 Hz navmesh resync, same zone duplication after the reparent, same
## everything. Nothing in a stock Godot log says how fast the game was actually running, where the
## time went, or how long the player had been in the zone. So a log could neither confirm nor rule
## out a hypothesis, and every diagnosis stayed a guess.
##
## This prints one heartbeat every REPORT_INTERVAL seconds with the numbers that separate the
## candidate causes from each other:
##   - fps / worst frame  -> is it a steady low framerate or a hitch train?
##   - proc vs phys vs nav -> main-thread script, physics, or navigation?
##   - PIPELINE_COMPILATIONS_* -> shader/PSO stutter (the "delete the shader cache" theory) shows up
##     here and NOWHERE else; flat counters exonerate it in one line.
##   - 3d active/pairs/islands -> the Jolt-broadphase-at-astronomic-coordinates signature.
##   - nav maps/regions/polys -> how many NavigationRegion3D the zone duplication actually left behind.
##   - nodes/orphans/mem -> a leak that builds up over minutes (the healthy reference logs were only
##     6 s and 44 s long; the broken ones 90 s and 324 s — duration alone may be the discriminator).
##   - dist-from-origin -> f32 quantisation is a function of this number, so it belongs in the log.
##
## Every line carries a wall-clock stamp and an uptime, which also gives every OTHER line in the log
## a time anchor: stock Godot logs have no timestamps at all, so "973 warnings" was only turnable
## into a rate by calibrating against livekit's 5 s debug timer.
##
## Client only. `dedicated_server` has its own richer [Perf] line in server.gd.

## Seconds between heartbeats. 4 s is ~15 lines/min — negligible next to the 3 Hz navmesh spam, and
## still short enough to catch the moment a session tips over.
const REPORT_INTERVAL: float = 4.0

## A frame this long is reported on its own line, immediately, with the time it happened. Below the
## threshold frames only feed the window's worst-frame figure.
const HITCH_MS: float = 100.0

## Recount the planet subtrees only every Nth heartbeat: it is an O(nodes) GDScript walk and the
## figure moves slowly. 3 => every 12 s at REPORT_INTERVAL 4 s.
const DEEP_EVERY: int = 3

var enabled: bool = true

var _t: float = 0.0
var _frames: int = 0
var _worst_ms: float = 0.0
var _worst_at: float = 0.0
var _hitches: int = 0
## Peak of the two INSTANTANEOUS engine monitors over the window. Peak ONLY, deliberately: each
## holds the last frame's figure and does not necessarily move every frame, so averaging the samples
## produced a nonsense — 138 samples averaging 545 ms over a window whose real length was 23 s, i.e.
## 75 seconds of "process time" inside 23 seconds of wall clock. The peak is a real frame's real
## figure and is the only thing these monitors can honestly supply here. Everything else about frame
## timing now comes from _last_frame_usec below, which is measured rather than reported.
var _proc_max: float = 0.0
var _phys_max: float = 0.0
## Wall clock at the previous _process, so a frame's REAL duration can be measured instead of taken
## from `delta`.
##
## `delta` is what the engine tells the game the step was, and it is CLAMPED: a frame whose
## TIME_PROCESS read 12 072 ms arrived here as 146 ms. Everything derived from it was therefore
## wrong in the same direction — the hitch detector was blind above ~150 ms (which is why `worst=`
## kept landing on 146-150 ms, a ceiling and not a coincidence), and `_t` accumulated 4.0 s of
## "window" across 23.0 s of real time, so every ms/s on the [CPerf+] line was overstated ~6x in
## exactly the windows that mattered most.
var _last_frame_usec: int = 0
## Physics steps actually achieved per second, against the configured target. The one number that
## says whether a big `phys=` is a PROBLEM: this project runs `physics/3d/run_on_separate_thread`,
## so the physics step does not sit inside the render frame and a fat physics figure next to a
## healthy fps is not a contradiction. If this stays at the target while fps sags, physics is not
## what is holding the frame; if it collapses, it is (and the game is running in slow motion).
var _phys_frames_prev: int = 0
var _reports: int = 0
var _boot_ms: int = 0
var _pipe_prev: Array[int] = [0, 0, 0, 0, 0]

## name -> usec accumulated since the last heartbeat, and how many times it ran. Filled by
## scope_begin/scope_end from whatever code wants to account for itself (planet_body's 3 Hz spin
## refresh is the first customer).
var _scope_usec: Dictionary = {}
var _scope_hits: Dictionary = {}
## Same accounting, but for ONE frame, so a hitch can be asked what ran in it instead of being
## reported as a bare millisecond count. Read and cleared in _process.
##
## The autoload processes before everything else, so when _process runs for frame N this still holds
## frame N-1 — which is exactly the frame `delta` measures, and therefore the frame that hitched.
##
## One distortion to keep in mind: a scope that spans an await (rock:cuts does) books ALL of its
## time to the frame it ENDED in, so it can be blamed for time it spent waiting in earlier frames.
var _frame_usec: Dictionary = {}
## Node count at the previous frame, so a hitch can say whether the tree grew or shrank across it —
## a spawn or a cleanup burst is invisible in a timing scope but obvious here.
var _prev_nodes: int = 0
## Filled by the deep census (_walk) every DEEP_EVERY reports.
var _deep: Dictionary = {}
## name -> last value pushed by gauge(). For counts a scope timer cannot express (nodes visited).
var _gauges: Dictionary = {}

const _PIPE_MONITORS: Array[int] = [
	Performance.PIPELINE_COMPILATIONS_CANVAS,
	Performance.PIPELINE_COMPILATIONS_MESH,
	Performance.PIPELINE_COMPILATIONS_SURFACE,
	Performance.PIPELINE_COMPILATIONS_DRAW,
	Performance.PIPELINE_COMPILATIONS_SPECIALIZATION,
]


func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		enabled = false
		set_process(false)
		return
	# `--no-perf` on the command line turns it off for anyone who finds the lines noisy; nothing else
	# in the game reads it, so it costs one array scan at boot.
	if "--no-perf" in OS.get_cmdline_args():
		enabled = false
		set_process(false)
		return
	_boot_ms = Time.get_ticks_msec()
	# Seed the node census so the first hitch line reports a real delta and not the whole tree.
	_prev_nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_print_machine()


## One boot line describing the machine. Comparing two players' logs starts here — GPU, driver,
## core count, RAM, window size and vsync are exactly the fields we had to go hunting for by hand in
## the Vulkan banner (which gives the adapter and nothing else).
func _print_machine() -> void:
	var mem: Dictionary = OS.get_memory_info()
	var drv: PackedStringArray = OS.get_video_adapter_driver_info()
	print("[CPerf] machine gpu='%s' driver=%s cpu='%s' x%d ram_phys=%s ram_avail=%s | window=%s vsync=%d max_fps=%d refresh=%.0fHz | v=%s" % [
		RenderingServer.get_video_adapter_name(),
		" ".join(drv),
		OS.get_processor_name(), OS.get_processor_count(),
		String.humanize_size(int(mem.get("physical", -1))),
		String.humanize_size(int(mem.get("available", -1))),
		str(DisplayServer.window_get_size()),
		int(DisplayServer.window_get_vsync_mode()),
		Engine.max_fps,
		DisplayServer.screen_get_refresh_rate(),
		Engine.get_version_info().get("string", "?"),
	])


# ------------------------------------------------------------------
# Instrumentation API — for callers that want to account for themselves
# ------------------------------------------------------------------

## Start timing a named section. Returns the token to hand back to scope_end().
## Returns 0 (and scope_end does nothing) when the heartbeat is off, so an instrumented call site
## costs one boolean test in that case.
func scope_begin() -> int:
	if not enabled:
		return 0
	return Time.get_ticks_usec()


func scope_end(scope_name: String, token: int) -> void:
	if not enabled or token == 0:
		return
	var spent: int = Time.get_ticks_usec() - token
	_scope_usec[scope_name] = int(_scope_usec.get(scope_name, 0)) + spent
	_scope_hits[scope_name] = int(_scope_hits.get(scope_name, 0)) + 1
	_frame_usec[scope_name] = int(_frame_usec.get(scope_name, 0)) + spent


## What the instrumented scopes cost in the frame just gone. Empty means the hitch happened in code
## that carries no scope at all — which is itself the finding: keep adding scopes until it is not.
func _frame_breakdown() -> String:
	if _frame_usec.is_empty():
		return "no instrumented scope ran"
	var parts: PackedStringArray = []
	for k: String in _frame_usec.keys():
		parts.append("%s=%.1fms" % [k, float(_frame_usec[k]) / 1000.0])
	return " ".join(parts)


## Record a plain number to show in the next heartbeat (last value wins). For counts that no timer
## expresses — "how many nodes did the spin refresh walk this tick".
func gauge(gauge_name: String, value: float) -> void:
	if not enabled:
		return
	_gauges[gauge_name] = value


# ------------------------------------------------------------------
# Heartbeat
# ------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not enabled:
		return
	# Measured, not reported — see _last_frame_usec. The first frame has no interval behind it.
	var now: int = Time.get_ticks_usec()
	var prev: int = _last_frame_usec
	_last_frame_usec = now
	if prev == 0:
		return
	var ms: float = float(now - prev) / 1000.0

	_frames += 1
	var proc_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_proc_max = maxf(_proc_max, proc_ms)
	_phys_max = maxf(_phys_max, phys_ms)
	if ms > _worst_ms:
		_worst_ms = ms
		_worst_at = _uptime()
	var nodes: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	if ms >= HITCH_MS:
		_hitches += 1
		print("[CPerf!] %s up=%.1fs hitch %.0f ms (frame %d) | proc=%.0f phys=%.0f nav=%.1f ms | nodes=%d%+d | %s" % [
			_clock(), _uptime(), ms, Engine.get_frames_drawn(),
			proc_ms, phys_ms, Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0,
			nodes, nodes - _prev_nodes,
			_frame_breakdown()])
	_prev_nodes = nodes
	_frame_usec.clear()
	# Real seconds, so the window this heartbeat divides by is the window that actually elapsed.
	_t += ms / 1000.0
	if _t < REPORT_INTERVAL:
		return
	_report()
	_t = 0.0
	_frames = 0
	_worst_ms = 0.0
	_hitches = 0
	_proc_max = 0.0
	_phys_max = 0.0
	_scope_usec.clear()
	_scope_hits.clear()


func _report() -> void:
	_reports += 1
	var window: float = maxf(_t, 0.001)
	var fps: float = float(_frames) / window
	var phys_now: int = Engine.get_physics_frames()
	var phys_hz: float = float(phys_now - _phys_frames_prev) / window
	_phys_frames_prev = phys_now

	var pipe_now: Array[int] = []
	var pipe_delta: Array[String] = []
	for i: int in _PIPE_MONITORS.size():
		var v: int = int(Performance.get_monitor(_PIPE_MONITORS[i]))
		pipe_now.append(v)
		pipe_delta.append(str(v - _pipe_prev[i]))
	_pipe_prev = pipe_now

	print("[CPerf] %s up=%.1fs | fps=%.1f worst=%.0fms@%.1fs hitches=%d | win=%.1fs proc<=%.0f phys<=%.0f@%.0f/%dHz nav=%.2f ms | draw=%d obj=%d prim=%s | 3d act=%d pairs=%d isl=%d | nav maps=%d reg=%d poly=%d | nodes=%d orphan=%d res=%d | mem=%s vram=%s | pipe+=%s" % [
		_clock(), _uptime(),
		fps, _worst_ms, _worst_at, _hitches,
		window, _proc_max,
		_phys_max, phys_hz, Engine.physics_ticks_per_second,
		Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		Globals.format_thousands(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)),
		int(Performance.get_monitor(Performance.NAVIGATION_3D_ACTIVE_MAPS)),
		int(Performance.get_monitor(Performance.NAVIGATION_3D_REGION_COUNT)),
		int(Performance.get_monitor(Performance.NAVIGATION_3D_POLYGON_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		String.humanize_size(int(Performance.get_monitor(Performance.MEMORY_STATIC))),
		String.humanize_size(int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))),
		"/".join(pipe_delta),
	])

	# Second line: what the engine monitors cannot know. Kept separate so the first line stays a
	# fixed set of columns that a script can parse across versions.
	var parts: PackedStringArray = []
	for k: String in _scope_usec.keys():
		var ms_per_s: float = float(_scope_usec[k]) / 1000.0 / window
		parts.append("%s=%.1fms/s x%d" % [k, ms_per_s, int(_scope_hits.get(k, 0))])
	for k: String in _gauges.keys():
		parts.append("%s=%s" % [k, str(_gauges[k])])
	parts.append_array(_world_context())
	if not parts.is_empty():
		print("[CPerf+] %s | %s" % [_clock(), " | ".join(parts)])


## Game-specific context: where the local player is, in which frame, and how big the tree hanging
## off each planet has grown. The last one is the cost driver of planet_body's 3 Hz refresh, and it
## is the number that a zone duplication silently doubles.
func _world_context() -> PackedStringArray:
	var out: PackedStringArray = []
	var tree: SceneTree = get_tree()
	if tree == null:
		return out

	# The local player is the one node whose distance from the world origin sets the f32 quantisation
	# every other physics number in this log inherits. NetworkOrchestrator owns it; nothing else here
	# depends on the network being up, so a null agent just drops the field.
	var agent: Node = NetworkOrchestrator.network_agent if "network_agent" in NetworkOrchestrator else null
	var me: Node = agent.player_entity if agent != null and "player_entity" in agent else null
	if me is Node3D and (me as Node3D).is_inside_tree():
		var me3: Node3D = me as Node3D
		# NOT "%.3e": GDScript's % operator has no scientific conversion, so that spec raised
		# "String formatting error: unsupported format character" on EVERY heartbeat — 94 errors in a
		# 7-minute session, each one printing a GDScript backtrace through the OpenTelemetry bridge,
		# and the field itself reached the log as the literal text "%.3e m". The monitor was costing
		# frame time and reporting nothing, which is the one thing a monitor may never do.
		var dist: float = me3.global_position.length()
		var mag: int = 0 if dist <= 0.0 else int(floor(log(dist) / log(10.0)))
		out.append("origin_dist=%.3fe%d m" % [dist / pow(10.0, mag), mag])
		var parent: Node = me3.get_parent()
		out.append("frame=%s" % (parent.name if parent != null else "<none>"))

	# Deep counts only every DEEP_EVERY reports: ONE recursive walk of the whole tree, which is the
	# same order of work as the 3 Hz spin refresh does anyway — but doing it 30x/min would not be.
	if _reports % DEEP_EVERY == 1:
		_deep.clear()
		_walk(tree.root, "")
		for k: String in _deep.keys():
			out.append("%s=%d" % [k, _deep[k]])
	return out


## Recursive census. `planet` is the name of the Planet ancestor we are under, if any, so each
## planet's subtree size is reported separately — that subtree is exactly what planet_body's spin
## refresh walks 3x/s, and exactly what a duplicated zone silently doubles.
func _walk(node: Node, planet: String) -> void:
	if node is Planet:
		planet = node.name
	elif planet != "":
		_bump("subtree:" + planet)
	if node is NavigationRegion3D:
		_bump("navregions")
	elif node is RigidBody3D:
		_bump("rigidbodies")
	elif node is Area3D:
		_bump("areas")
	if node.is_in_group("cargo_depots"):
		_bump("cargo_depots")
	elif node.is_in_group("miningrock"):
		_bump("miningrocks")
	for c: Node in node.get_children():
		_walk(c, planet)


func _bump(key: String) -> void:
	_deep[key] = int(_deep.get(key, 0)) + 1


func _uptime() -> float:
	return float(Time.get_ticks_msec() - _boot_ms) / 1000.0


func _clock() -> String:
	return Time.get_time_string_from_system()
