extends Node
## Client-side machine dump + performance heartbeat — the thing the 5 FPS reports kept lacking.
##
## TWO HALVES, and only the first one is always on:
##
##  1. THE BOOT DUMP, printed by every client on every start. Machine, GPU driver, every screen, the
##     runtime render settings, physics/threading, and the player's own settings.ini. It is a handful
##     of lines ONCE, it costs nothing, and it is the half of a bug report players never think to
##     send: a 4K screen with shadows at 300 m is a different game from the one we run here, and the
##     difference used to be in no log at all.
##
##  2. THE HEARTBEAT, everything below, printed ONLY when `debug_perf=true` is set in client.ini
##     (see client_config.gd — a packaged build takes no command line, so an ini key is the only
##     switch a player can reach). With the key off, this autoload stops processing entirely, every
##     scope_begin() in the game returns 0, and not one perf line is written. With it on, the client
##     is a measuring instrument for the duration of the session: expect ~6 lines every 2 s.
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
## The other lines of the heartbeat, and what each is for:
##   [CPerf@] a marker every time the game state or the player's parent frame changes. THE FIRST
##            LINE TO LOOK FOR: the reports we are chasing say "it is slow from the spawn", and this
##            is what puts an uptime on the spawn so every other line can be read as before/after.
##   [CPerf#] frame-time percentiles + histogram: tells 12 even frames apart from 55 fast ones and a
##            900 ms stall, which no average ever will.
##   [CPerf$] memory on both sides of the wall, including how much RAM the MACHINE has left and the
##            drift since boot (a swapping client looks perfectly healthy in every other line).
##   [CPerf~] engine counters and the game's custom monitors (network events/s), otherwise visible
##            only in the editor profiler.
##   [CPerf*] a class census of the scene tree: not "48213 nodes" but which 48213.
##   [CPerf!] one line per frame over HITCH_MS, capped per window, with what ran in that frame.
##   [CPerf!!] a marker whenever a window drops under LOW_FPS, which also schedules the deep census.
##   [CPerf=] a one-paragraph session summary at exit.
##
## Client only. `dedicated_server` has its own richer [Perf] line in server.gd.

## Seconds between heartbeats. The heartbeat only ever runs when a player has deliberately turned it
## on to reproduce a problem, so it is tuned for diagnosis, not for background noise: 2 s is short
## enough to show a collapse building up over the first seconds of a spawn.
const REPORT_INTERVAL: float = 2.0

## A frame this long is reported on its own line, immediately, with the time it happened. Below the
## threshold frames only feed the window's worst-frame figure. 50 ms = under 20 fps for one frame.
const HITCH_MS: float = 50.0

## Recount the planet subtrees only every Nth heartbeat: it is an O(nodes) GDScript walk and the
## figure moves slowly. 2 => every 4 s at REPORT_INTERVAL 2 s.
const DEEP_EVERY: int = 2

## A window slower than this gets an immediate [CPerf!!] line and forces the deep
## census on the next heartbeat. 20 fps is well under anything playable and well over the 5-6 fps of
## the reports we are chasing, so it fires on the way DOWN — the interesting part.
const LOW_FPS: float = 20.0

## Hitch lines are rate-limited PER WINDOW. A client stuck at 5 fps has every single frame over the
## threshold, and every print() here goes through CustomLogger -> Obs -> the C# OpenTelemetry bridge
## (milliseconds, not microseconds — see the --net-echo comment in client.gd), so an uncapped hitch
## detector would spend the whole frame budget describing the frame budget. The suppressed count is
## reported in the heartbeat, so nothing is lost but the repetition.
const MAX_HITCH_LINES: int = 6

## Per-frame durations kept for the percentile/histogram line. 8192 covers ~2 minutes at 60 fps, far
## more than one window, and caps the memory at 32 KB.
const MAX_SAMPLES: int = 8192

## How many entries the class census and the scope ranking print.
const TOP_CLASSES: int = 15

## `debug_perf=true` in client.ini (or `--perf-verbose` for us). OFF by default, and when it is off
## NOTHING here runs: no heartbeat, no per-frame sample, no census, and every scope_begin() in the
## game returns 0 so the instrumented call sites cost one boolean test. See client_config.gd for why
## this is an ini key and not a command-line flag.
var enabled: bool = false

## Live dials. The consts above are the defaults; each can be pinned from client.ini
## (debug_perf_interval / debug_perf_hitch_ms / debug_perf_deep_every) so a user can be talked into a
## finer or coarser setting without a new build.
var _interval: float = REPORT_INTERVAL
var _hitch_ms: float = HITCH_MS
var _deep_every: int = DEEP_EVERY

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

## Verbose only. Every frame's measured duration in the current window, for the percentile and
## histogram line: `fps=12` says nothing about whether that is 12 even frames or 55 fast ones and a
## 900 ms stall, and those two have entirely different causes.
var _samples: PackedFloat32Array = PackedFloat32Array()
## Hitch lines already printed in this window, against MAX_HITCH_LINES, and how many were dropped.
var _hitch_lines: int = 0
var _hitch_suppressed: int = 0
## Since-boot totals, for the [CPerf=] line printed when the game exits. A session summary is what
## makes two players' logs comparable without anyone having to average 300 heartbeats by hand.
var _session_frames: int = 0
var _session_hitches: int = 0
var _session_worst_ms: float = 0.0
var _session_worst_at: float = 0.0
var _session_usec: Dictionary = {}
## Windows seen under LOW_FPS, and a request to run the deep census on the next heartbeat whatever
## the cadence says — set when one of those windows happens, so the expensive walk lands where it is
## useful instead of on a schedule.
var _low_windows: int = 0
var _force_deep: bool = false
## Class name -> count, filled by the deep walk. `nodes=48213` is a number; a class
## histogram is a cause.
var _classes: Dictionary = {}
## Nodes with _process / _physics_process actually enabled, from the same walk: the population that
## the `proc=` and `phys=` figures are divided among.
var _procs: int = 0
var _phys_procs: int = 0
## Previous value of each custom monitor (network/events_received, ...), for a per-second rate.
var _custom_prev: Dictionary = {}
## Available system RAM at boot, so the heartbeat can report the TREND. A client that is swapping
## has a perfectly healthy-looking [CPerf] line and an unusable machine.
var _mem_avail_boot: int = 0
## The exit summary must print exactly once, and both paths that can trigger it (window close and
## tree exit) do fire on a normal quit.
var _summarised: bool = false
## Last game state and last parent frame of the local player, for the [CPerf@] markers. Polled
## rather than signalled: GameOrchestrator has no state signal, and adding one for the benefit of a
## monitor would be the monitor changing the game.
var _last_state: Variant = null
var _last_frame_name: String = ""
## What the previous heartbeat cost to produce, shown on the next [CPerf~] line.
##
## Expect ~1 ms in a real build and TEN TIMES that in a local editor run: this dev checkout has no
## Microsoft.Extensions.Logging.* assemblies next to the binary, so every single print() throws a
## FileNotFoundException inside the C# bridge and gets a full backtrace appended to the log. The
## exported build ships those DLLs (build/*/data_DyingStar_*/), so a player's figure is the honest
## one — do not size the verbosity from what this number reads in the editor.
var _report_cost_ms: float = 0.0

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
		set_process(false)
		return
	_boot_ms = Time.get_ticks_msec()
	_mem_avail_boot = int(OS.get_memory_info().get("available", -1))

	# ALWAYS, whatever debug_perf says. These lines are printed once and describe the machine the
	# game is about to run on; they are worth having in EVERY log, including the ones sent for a bug
	# that has nothing to do with performance, and they cost nothing after boot.
	_print_machine()
	ClientConfig.boot_report()
	_print_boot_detail()

	# `--no-perf` still wins, so a developer with debug_perf=true in their working client.ini can get
	# a quiet run without editing the file.
	var args: PackedStringArray = OS.get_cmdline_args()
	enabled = ("--perf-verbose" in args or ClientConfig.get_bool("debug_perf", false)) and not ("--no-perf" in args)
	if not enabled:
		set_process(false)
		# Say so, once, and say where. A log that arrives without perf lines is otherwise
		# indistinguishable from one where the player DID set the key and the file was never read —
		# which is exactly the failure this path exists to make visible.
		print((
			"[CPerf] performance logging OFF — to report a performance problem,"
			+ " set `debug_perf=true` in %s and restart the game."
		) % ClientConfig.expected_path())
		return

	_interval = maxf(0.5, ClientConfig.get_float("debug_perf_interval", REPORT_INTERVAL))
	_hitch_ms = maxf(8.0, ClientConfig.get_float("debug_perf_hitch_ms", HITCH_MS))
	_deep_every = maxi(1, ClientConfig.get_int("debug_perf_deep_every", DEEP_EVERY))
	# Seed the node census so the first hitch line reports a real delta and not the whole tree.
	_prev_nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	print("[CPerf] performance logging ON — every %.1fs, hitch>%.0fms, census every %d reports. Source: %s" % [
		_interval, _hitch_ms, _deep_every, ClientConfig.source()])


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


## Everything about this machine, this build and this user's settings that a heartbeat can never
## show because it does not change. Verbose only, printed once. This is the half of a bug report
## that no player thinks to send: driver version, window mode, render scale, MSAA, and above all
## what they turned on in the Settings menu — a 4K screen with shadows at 300 m and a 3D scale of 1.0
## is a different game from the one we run here, and the difference has never been in any log.
func _print_boot_detail() -> void:
	print("[CPerf] os=%s %s (%s) arch=%s | exe=%s | cwd_ini=%s | user_dir=%s | log=%s" % [
		OS.get_name(), OS.get_version(), OS.get_distribution_name(), Engine.get_architecture_name(),
		OS.get_executable_path(),
		ClientConfig.source(),
		ProjectSettings.globalize_path("user://"),
		ProjectSettings.globalize_path(str(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log"))),
	])

	# Feature tags cannot be enumerated, so this is the list that actually changes behaviour here.
	# `devmode` in particular REROUTES the websocket url in client.gd, and a build tagged `debug`
	# runs with checks a release build does not have — both have been mistaken for slowness before.
	var tags: PackedStringArray = []
	for tag: String in ["editor", "template", "debug", "release", "standalone", "dedicated_server",
			"devmode", "windows", "linuxbsd", "macos", "web", "x86_64", "arm64", "mono", "double"]:
		if OS.has_feature(tag):
			tags.append(tag)
	# The adapter NAME is already on the machine line; vendor/type/api are not, and "is this the
	# integrated GPU?" (type) plus the API version is most of a driver diagnosis.
	print("[CPerf] features=%s | args=%s | session=%s/%s | gpu_vendor=%s type=%d api=%s" % [
		",".join(tags),
		" ".join(OS.get_cmdline_args()),
		OS.get_environment("XDG_SESSION_TYPE"), OS.get_environment("WAYLAND_DISPLAY"),
		RenderingServer.get_video_adapter_vendor(),
		RenderingServer.get_video_adapter_type(), RenderingServer.get_video_adapter_api_version(),
	])

	# Every screen, not just the current one: a laptop rendering onto a 4K external at 60 Hz while
	# the game thinks it is on the built-in panel is a classic source of "my fps is half yours".
	var screens: PackedStringArray = []
	for i: int in DisplayServer.get_screen_count():
		screens.append("#%d %s@%.0fHz dpi=%d scale=%.2f" % [
			i, str(DisplayServer.screen_get_size(i)), DisplayServer.screen_get_refresh_rate(i),
			DisplayServer.screen_get_dpi(i), DisplayServer.screen_get_scale(i)])
	print("[CPerf] window mode=%d size=%s pos=%s on_screen=%d | screens: %s" % [
		int(DisplayServer.window_get_mode()), str(DisplayServer.window_get_size()),
		str(DisplayServer.window_get_position()), DisplayServer.window_get_current_screen(),
		" ".join(screens)])

	# The RUNTIME rendering configuration, read off the viewport rather than off ProjectSettings:
	# the settings menu changes these live, so the project defaults would describe a game the player
	# is not running.
	var vp: Viewport = get_viewport()
	if vp != null:
		print((
			"[CPerf] render method=%s | viewport=%s scaling3d=%d x%.2f msaa3d=%d ssaa=%d taa=%s"
			+ " debanding=%s vrs=%d | shadow_atlas=%d dir_shadow=%s occlusion=%s aniso=%s"
		) % [
			str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "?")),
			str(vp.get_visible_rect().size),
			int(vp.scaling_3d_mode), vp.scaling_3d_scale, int(vp.msaa_3d), int(vp.screen_space_aa),
			vp.use_taa, vp.use_debanding, int(vp.vrs_mode),
			vp.positional_shadow_atlas_size,
			str(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size", "?")),
			str(ProjectSettings.get_setting("rendering/occlusion_culling/use_occlusion_culling", "?")),
			str(ProjectSettings.get_setting("rendering/textures/default_filters/anisotropic_filtering_level", "?")),
		])

	print("[CPerf] physics engine=%s ticks=%d separate_thread=%s | worker_threads=%s | time_scale=%.2f | mem_boot avail=%s phys=%s" % [
		str(ProjectSettings.get_setting("physics/3d/physics_engine", "?")),
		Engine.physics_ticks_per_second,
		str(ProjectSettings.get_setting("physics/3d/run_on_separate_thread", "?")),
		str(ProjectSettings.get_setting("threading/worker_pool/max_threads", "?")),
		Engine.time_scale,
		String.humanize_size(_mem_avail_boot),
		String.humanize_size(int(OS.get_memory_info().get("physical", -1))),
	])

	# What the player chose in the menu (user://settings.ini). Resolution, vsync, max fps, fov,
	# shadows and shadow distance all live here and all move the framerate by more than most bugs.
	print("[CPerf] settings.ini %s" % str(SettingsManager.load_settings()))


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
	_session_usec[scope_name] = int(_session_usec.get(scope_name, 0)) + spent


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
# Markers — WHEN something happened, so the rest of the log can be read as before/after
# ------------------------------------------------------------------

## The reports we are chasing say "it is slow from the moment I spawn". That is a claim about a
## MOMENT, and a log with no marker for the spawn cannot support or refute it: every heartbeat looks
## the same and nothing says which of them is the first one in the world. Checked every frame (one
## property read and a compare) so the marker lands on the frame the transition happened.
func _check_state_change() -> void:
	var st: Variant = GameOrchestrator.current_state
	if st == _last_state:
		return
	var from_name: String = _state_name(_last_state)
	_last_state = st
	print("[CPerf@] %s up=%.1fs state %s -> %s | frame=%d nodes=%d res=%d | mem=%s vram=%s" % [
		_clock(), _uptime(), from_name, _state_name(st),
		Engine.get_frames_drawn(),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		String.humanize_size(int(Performance.get_monitor(Performance.MEMORY_STATIC))),
		String.humanize_size(int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))),
	])


func _state_name(st: Variant) -> String:
	if st == null:
		return "<none>"
	for k: String in GameOrchestrator.GameStates.keys():
		if GameOrchestrator.GameStates[k] == st:
			return k
	return str(st)


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
	# Keep the frame itself, not just the window's worst: the shape of the distribution is what
	# separates "the machine is too slow for this scene" from "something stalls once a second".
	if _samples.size() < MAX_SAMPLES:
		_samples.append(ms)
	_session_frames += 1
	if ms > _session_worst_ms:
		_session_worst_ms = ms
		_session_worst_at = _uptime()
	# One int compare per frame, so the spawn marker lands on the frame it happened rather than up to
	# a whole window later. "It is slow from the spawn" is a claim about a moment.
	_check_state_change()
	var nodes: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	if ms >= _hitch_ms:
		_hitches += 1
		_session_hitches += 1
		# Rate-limited: see MAX_HITCH_LINES. Below 10 fps EVERY frame is a hitch, and printing them
		# all makes the client slower than the bug does.
		if _hitch_lines < MAX_HITCH_LINES:
			_hitch_lines += 1
			print((
				"[CPerf!] %s up=%.1fs hitch %.0f ms (frame %d) | proc=%.0f phys=%.0f nav=%.1f ms"
				+ " | nodes=%d%+d | %s | draw=%d obj=%d act=%d pairs=%d mem=%s vram=%s"
			) % [
				_clock(), _uptime(), ms, Engine.get_frames_drawn(),
				proc_ms, phys_ms, Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0,
				nodes, nodes - _prev_nodes,
				_frame_breakdown(),
				int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
				int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
				int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
				int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
				String.humanize_size(int(Performance.get_monitor(Performance.MEMORY_STATIC))),
				String.humanize_size(int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))),
			])
		else:
			_hitch_suppressed += 1
	_prev_nodes = nodes
	_frame_usec.clear()
	# Real seconds, so the window this heartbeat divides by is the window that actually elapsed.
	_t += ms / 1000.0
	if _t < _interval:
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
	_samples.clear()
	_hitch_lines = 0
	_hitch_suppressed = 0


func _report() -> void:
	var report_started: int = Time.get_ticks_usec()
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

	print((
		"[CPerf] %s up=%.1fs | fps=%.1f worst=%.0fms@%.1fs hitches=%d"
		+ " | win=%.1fs proc<=%.0f phys<=%.0f@%.0f/%dHz nav=%.2f ms"
		+ " | draw=%d obj=%d prim=%s | 3d act=%d pairs=%d isl=%d"
		+ " | nav maps=%d reg=%d poly=%d | nodes=%d orphan=%d res=%d"
		+ " | mem=%s vram=%s | pipe+=%s"
	) % [
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
	if _hitch_suppressed > 0:
		print("[CPerf] %s hitch lines suppressed this window: %d (over %.0f ms each)" % [
			_clock(), _hitch_suppressed, _hitch_ms])

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

	_report_extras(fps)
	# Measured and reported, because this monitor prints ~6 lines per heartbeat through a logger that
	# costs milliseconds: any figure it produces has to be readable NEXT to the price of producing it,
	# or the instrument starts describing itself. Shown on the next [CPerf~].
	_report_cost_ms = float(Time.get_ticks_usec() - report_started) / 1000.0


# ------------------------------------------------------------------
# The rest of the heartbeat
# ------------------------------------------------------------------

## The extra lines, in a fixed order so a support answer can say "send me the [CPerf#] lines".
func _report_extras(fps: float) -> void:
	_print_distribution()
	_print_memory()
	_print_engine()
	if not _classes.is_empty():
		_print_classes()
	if fps < LOW_FPS:
		_low_windows += 1
		# The deep census is O(nodes); running it on the spot would land inside the very frames we
		# are complaining about. Asking for it on the NEXT heartbeat gets the same answer 2 s later
		# without adding to the stall being reported.
		_force_deep = true
		# Deliberately short: every figure worth having is on the [CPerf] line printed a moment ago.
		# This is a MARKER — one greppable line per bad window, so "when did it start and how long
		# did it last" is a grep and not a reading of three hundred heartbeats.
		print((
			"[CPerf!!] %s up=%.1fs LOW fps=%.1f (low window %d)"
			+ " | worst=%.0fms hitches=%d(+%d suppressed) | deep census forced next heartbeat"
		) % [
			_clock(), _uptime(), fps, _low_windows,
			_worst_ms, _hitches, _hitch_suppressed,
		])


## Frame-time percentiles and a histogram. `fps=12` is an average and averages hide the two cases we
## actually have to tell apart: 12 evenly spaced frames (the machine cannot draw the scene) versus 55
## fast frames and a 900 ms stall (something blocks the main thread once a second). p99 and the
## over-33 ms share answer that in one line.
func _print_distribution() -> void:
	var n: int = _samples.size()
	if n == 0:
		return
	var ordered: PackedFloat32Array = _samples.duplicate()
	ordered.sort()
	# Buckets: 120 fps, 60 fps, 30 fps, 20 fps, 10 fps, 4 fps, worse. The edges sit just ABOVE the
	# exact frame times (17 rather than 16.7): a vsynced 60 Hz client measures 16.7-16.9 ms, and on an
	# exact edge half of a perfectly healthy window ends up filed one bucket too slow.
	var edges: Array[float] = [8.0, 17.0, 34.0, 50.0, 100.0, 250.0]
	var buckets: Array[int] = [0, 0, 0, 0, 0, 0, 0]
	var total_ms: float = 0.0
	var stalled_ms: float = 0.0
	for v: float in _samples:
		total_ms += v
		if v >= 34.0:
			stalled_ms += v
		var i: int = 0
		while i < edges.size() and v >= edges[i]:
			i += 1
		buckets[i] += 1
	print((
		"[CPerf#] %s frames=%d p50=%.1f p90=%.1f p99=%.1f max=%.1f ms"
		+ " | <8=%d <17=%d <34=%d <50=%d <100=%d <250=%d 250+=%d"
		+ " | %.0f%% of the window was spent in frames over 34 ms"
	) % [
		_clock(), n, _pct(ordered, 0.50), _pct(ordered, 0.90), _pct(ordered, 0.99), _pct(ordered, 1.0),
		buckets[0], buckets[1], buckets[2], buckets[3], buckets[4], buckets[5], buckets[6],
		100.0 * stalled_ms / maxf(total_ms, 0.001)])


func _pct(ordered: PackedFloat32Array, q: float) -> float:
	var n: int = ordered.size()
	if n == 0:
		return 0.0
	return ordered[clampi(int(round(q * float(n - 1))), 0, n - 1)]


## Memory, on both sides of the wall. `mem=` in the main line is Godot's own static allocation; what
## a report never contains is how much RAM the MACHINE has left — a client that has started swapping
## has a perfectly healthy [CPerf] line and an unplayable game, and the trend since boot is what
## separates a leak from a big-but-stable world.
func _print_memory() -> void:
	var mem: Dictionary = OS.get_memory_info()
	var avail: int = int(mem.get("available", -1))
	var drift_mb: float = float(avail - _mem_avail_boot) / (1024.0 * 1024.0) if _mem_avail_boot > 0 else 0.0
	print((
		"[CPerf$] %s | godot static=%s peak=%s msgbuf=%s"
		+ " | system avail=%s (%+.0f MB since boot) free=%s stack=%s"
		+ " | vram=%s tex=%s buf=%s | objects=%d res=%d nodes=%d orphans=%d"
	) % [
		_clock(),
		String.humanize_size(OS.get_static_memory_usage()),
		String.humanize_size(OS.get_static_memory_peak_usage()),
		String.humanize_size(int(Performance.get_monitor(Performance.MEMORY_MESSAGE_BUFFER_MAX))),
		String.humanize_size(avail), drift_mb,
		String.humanize_size(int(mem.get("free", -1))),
		String.humanize_size(int(mem.get("stack", -1))),
		String.humanize_size(int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))),
		String.humanize_size(int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))),
		String.humanize_size(int(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED))),
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
	])


## Engine counters and every CUSTOM monitor registered by the game — currently the network agent's
## events_received / events_sent, whose PER-SECOND rate is the one number that says whether a client
## is drowning in replication traffic. Custom monitors are otherwise visible only in the editor
## profiler, i.e. never on a player's machine.
func _print_engine() -> void:
	var parts: PackedStringArray = []
	for cname: StringName in Performance.get_custom_monitor_names():
		var raw: Variant = Performance.get_custom_monitor(cname)
		if not (raw is int or raw is float):
			continue
		var v: float = float(raw)
		var prev: float = float(_custom_prev.get(cname, v))
		_custom_prev[cname] = v
		parts.append("%s=%.0f (%+.1f/s)" % [cname, v, (v - prev) / maxf(_interval, 0.001)])
	print("[CPerf~] %s | fps_engine=%d drawn=%d phys_frames=%d time_scale=%.2f max_fps=%d vsync=%d focused=%s | monitor_cost=%.2fms | %s" % [
		_clock(),
		Engine.get_frames_per_second(), Engine.get_frames_drawn(), Engine.get_physics_frames(),
		Engine.time_scale, Engine.max_fps, int(DisplayServer.window_get_vsync_mode()),
		DisplayServer.window_is_focused(),
		_report_cost_ms,
		" ".join(parts) if not parts.is_empty() else "no custom monitors",
	])


## What the tree is actually MADE of, top classes first. `nodes=48213` is a number; "MeshInstance3D
## =19004 CSGBox3D=8800" is a cause, and it is how a duplicated zone or a rock field that never
## despawns gives itself away without anyone guessing which subsystem to suspect.
func _print_classes() -> void:
	var counts: Dictionary = _classes
	var keys: Array = counts.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return int(counts[a]) > int(counts[b]))
	var parts: PackedStringArray = []
	for i: int in mini(TOP_CLASSES, keys.size()):
		parts.append("%s=%d" % [str(keys[i]), int(counts[keys[i]])])
	print("[CPerf*] %s classes (top %d of %d distinct) %s | nodes with _process=%d _physics_process=%d" % [
		_clock(), mini(TOP_CLASSES, keys.size()), keys.size(), " ".join(parts), _procs, _phys_procs])


# ------------------------------------------------------------------
# Session summary
# ------------------------------------------------------------------

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_summarise()


func _exit_tree() -> void:
	_summarise()


## The last lines of the log: one paragraph that describes the whole session. Without it, reading a
## player's log means averaging three hundred heartbeats by hand before two reports can be compared.
func _summarise() -> void:
	if not enabled or _summarised:
		return
	_summarised = true
	var up: float = maxf(_uptime(), 0.001)
	var totals: Dictionary = _session_usec
	var keys: Array = totals.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return int(totals[a]) > int(totals[b]))
	var parts: PackedStringArray = []
	for i: int in mini(TOP_CLASSES, keys.size()):
		parts.append("%s=%.2fs (%.1f%% of session)" % [
			str(keys[i]), float(totals[keys[i]]) / 1000000.0, 100.0 * float(totals[keys[i]]) / 1000000.0 / up])
	print((
		"[CPerf=] %s SESSION up=%.1fs frames=%d mean_fps=%.1f"
		+ " | worst=%.0fms@%.1fs hitches=%d low_windows=%d heartbeats=%d | top scopes: %s"
	) % [
		_clock(), up, _session_frames, float(_session_frames) / up,
		_session_worst_ms, _session_worst_at, _session_hitches, _low_windows, _reports,
		" ".join(parts) if not parts.is_empty() else "none"])


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
		var frame_name: String = str(parent.name) if parent != null else "<none>"
		out.append("frame=%s" % frame_name)
		# The player being REPARENTED (menu -> planet, planet -> ship, one zone -> another) is the
		# other moment worth stamping: it is when the zone content streams in, and it is where the
		# duplication bug used to double the tree. First appearance counts as a transition too, so
		# this line is also "the local player exists as of here".
		if frame_name != _last_frame_name:
			# NOT "%.3e" — GDScript's % has no scientific conversion and that spec raises a String
			# formatting error on every call. Same mantissa/exponent trick as above.
			print("[CPerf@] %s up=%.1fs player frame %s -> %s | nodes=%d | origin_dist=%.3fe%d m" % [
				_clock(), _uptime(), _last_frame_name if _last_frame_name != "" else "<none>",
				frame_name, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
				dist / pow(10.0, mag), mag])
			_last_frame_name = frame_name

	# Deep counts only every DEEP_EVERY reports: ONE recursive walk of the whole tree, which is the
	# same order of work as the 3 Hz spin refresh does anyway — but doing it 30x/min would not be.
	if _force_deep or _reports % _deep_every == 1:
		_force_deep = false
		_deep.clear()
		_classes.clear()
		_procs = 0
		_phys_procs = 0
		_walk(tree.root, "")
		for k: String in _deep.keys():
			out.append("%s=%d" % [k, _deep[k]])
	return out


## Recursive census. `planet` is the name of the Planet ancestor we are under, if any, so each
## planet's subtree size is reported separately — that subtree is exactly what planet_body's spin
## refresh walks 3x/s, and exactly what a duplicated zone silently doubles.
func _walk(node: Node, planet: String) -> void:
	# One extra dictionary bump and two flag reads per node. It doubles the cost of a walk that
	# already runs at most every few seconds, and it is the difference between knowing HOW MANY nodes
	# there are and knowing WHICH ones.
	var cls: String = node.get_class()
	_classes[cls] = int(_classes.get(cls, 0)) + 1
	if node.is_processing():
		_procs += 1
	if node.is_physics_processing():
		_phys_procs += 1
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
