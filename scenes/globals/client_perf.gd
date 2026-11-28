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
##   [CPerfV] where the video memory goes (VramCensus): 20 s after each state or player-frame change,
##            then every 5 min — the biggest textures, by format / folder, and what the renderer keeps itself.
##   [CPerf~] engine counters and the game's custom monitors (network events/s), otherwise visible
##            only in the editor profiler.
##   [CPerf*] a class census of the scene tree: not "48213 nodes" but which 48213.
##   [CPerf!] one line per frame over HITCH_MS, capped per window, with what ran in that frame.
##   [CPerf!!] a marker whenever a window drops under LOW_FPS, which also schedules the deep census.
##   [CPerfP] the physics burst of the window cut in four (steps, _physics_process scripts, the physics_frame
##            signal + 3D mouse picking, the engine: sync, collision callbacks, timers, Jolt) and its scripts.
##   [CPerfT] CPU per thread group (Linux): main, WorkerThread, .NET, tokio… — who burns the other cores.
##   [CPerfW] what the WorkerThreadPool tasks were, by site (PerfTasks): the names behind [CPerfT].
##   [CPerfG] GPU per render pass and per viewport — only with `--gpu-profile` on the command line, the
##            one switch that makes the renderer capture its timestamps (not reachable from a script).
##   [CPerf=] a one-paragraph session summary at exit.
##
## Client only. `dedicated_server` has its own richer [Perf] line in server.gd.

## Seconds between heartbeats. The heartbeat only ever runs when a player has deliberately turned it
## on to reproduce a problem, so it is tuned for diagnosis, not for background noise: 2 s is short
## enough to show a collapse building up over the first seconds of a spawn.
const REPORT_INTERVAL: float = 2.0
## Planet.GROUP, spelt out: an autoload that names Planet compiles and loads most of the game at boot,
## before its first frame (2026-11-19; test_boot_light_autoloads checks they agree).
const PLANET_GROUP := &"planet"

## A frame this long is reported on its own line, immediately, with the time it happened. Below the
## threshold frames only feed the window's worst-frame figure. 50 ms = under 20 fps for one frame.
const HITCH_MS: float = PerfMath.HITCH_MS

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
## The frame's `proc=` figure, SPLIT. TIME_PROCESS covers everything the idle step does — every
## _process callback, the message queue flush, and RenderingServer sync+draw — so a log reading
## `proc=161` next to 2 ms of instrumented scopes says only "it is not the network", and the last
## 5-6 fps report died exactly there: 155 ms of frame in no scope at all, unchanged while draw calls
## went 433 -> 3298 -> 566 and the node count moved by a thousand.
##
## Measured, not guessed, with two probes:
##   - this autoload is the FIRST node processed (autoloads head the tree), and `_tail` is a bare
##     node with a huge process_priority, so it is the LAST. The span between them is every
##     _process callback in the game -> `scripts=`.
##   - the viewport's own timers (viewport_set_measure_render_time) give what the RENDER THREAD and
##     the GPU spent on the same frame -> `rcpu=` / `rgpu=`.
## `proc` minus `scripts` minus `rcpu` is then the engine's own idle work. Three numbers, and the
## next log says which third of the frame to open rather than which to suspect.
var _scripts_usec: int = 0
var _frame_start_usec: int = 0
var _tail: Node = null
var _viewport_rid: RID = RID()
var _scripts_max: float = 0.0
var _rcpu_max: float = 0.0
var _rgpu_max: float = 0.0
## The LAST third of the idle step, which `scripts=`/`rcpu=` between them cannot see.
##
## `proc=162` next to `scripts<=13 rcpu<=1.1 rgpu<=4.4` (log Anthony 2026-09-09, 6.0 fps locked for
## 195 s) says 145-160 ms a frame is spent AFTER the last _process callback and BEFORE the end of
## the idle step, and `msgbuf` peaking at 24 KiB rules the deferred-call queue out. What is left
## there is `MessageQueue::flush()` + `RenderingServer::sync()` (the main thread BLOCKING on the
## render thread) then `RenderingServer::draw()`. Three probes close it:
##   - `frame_pre_draw` / `frame_post_draw` fire on the main thread around `draw()`, so tail ->
##     pre_draw is the flush+sync BLOCK (`sync=`) and pre -> post is the draw itself (`draw=`).
##   - `get_frame_setup_time_cpu()` is the render-thread work that `viewport_get_measured_render_time_cpu`
##     explicitly does NOT include — dirty-instance updates, AABB and BVH maintenance, light and
##     shadow culling setup (`setup=`). At origin_dist=8.05e10 m one float32 ulp is ~8 km, which is
##     exactly where a render scenario's AABBs would collapse into one blob; see
##     [[jolt-broadphase-f32-astronomic-coords]] for the same failure one layer down.
var _tail_usec: int = 0
var _predraw_usec: int = 0
var _postdraw_usec: int = 0
var _sync_max: float = 0.0
var _draw_max: float = 0.0
var _setup_max: float = 0.0
## The part of the frame that lies OUTSIDE everything above, measured the same way.
##
## Log `godot(6).log` (2026-09-09) closed the previous gap and opened this one: at 6.0 fps and
## 160-170 ms a frame, `scripts=1-4 rcpu=1.3 setup=0.1-0.7 sync=0-1 rsdraw=2-5`. Six milliseconds
## are accounted for, so ~155 ms sit between `frame_post_draw` of one frame and the first `_process`
## of the next. Only two things live there: the PHYSICS BURST (up to
## `max_physics_steps_per_frame` = 8 steps, whose wall clock no monitor reports — `phys=` is the max
## of ONE step, not the sum) and what `SceneTree::process()` does BEFORE the process group: transform
## notification flush, timers, tweens, and `_process_picking` (the 3D mouse pick, a physics raycast
## issued from the main thread, invisible to `TIME_PHYSICS_PROCESS`).
## `gap=` is the whole thing, `pre=` is only its second half.
var _phys_tail_usec: int = 0
var _gap_max: float = 0.0
var _pre_max: float = 0.0
## `pre=` cut in two, using the one hook Godot offers inside it.
##
## `SceneTree::process()` (4.7 source, scene/main/scene_tree.cpp) does, in this order and BEFORE it
## calls a single `_process`: the fixed-timestep-interpolation pass (off here — no
## `physics/common/physics_interpolation` in project.godot), `MainLoop::process`, `multiplayer->poll()`,
## `emit_signal("process_frame")`, `MessageQueue::flush()`, `flush_transform_notifications()`.
## Connecting to `process_frame` therefore plants a timestamp in the middle of the blind window:
##   - `pf=` phys tail -> process_frame : FTI, MainLoop, multiplayer poll.
##   - `tf=` process_frame -> first _process : the other `process_frame` handlers (every suspended
##     `await get_tree().process_frame` in the game resumes HERE, invisible to `scripts=`), the
##     message queue, and the flush of every transform the 8 physics steps just dirtied — which is
##     where 482 concave chunk bodies would be pushed back into Jolt at 8e10 m.
var _pframe_usec: int = 0
## Ablation for the last suspect inside `tf=`.
##
## `planet_body._place_at_time` rewrites the planet's basis a few times a second; every Node3D under
## it (subtree:Tarsis3 = 9026 nodes) has its global transform invalidated, and every CollisionObject3D
## among them lands in the transform-change list. The FLUSH of that list is not in the planet_spin
## scope — it happens later, in `SceneTree::process()`, inside `tf=` — and it pushes each body back
## into Jolt, whose float32 broadphase quantises to kilometres at 8e10 m. Read by
## [scenes/planet/planet_body.gd](scenes/planet/planet_body.gd).
var ablate_planet_spin: bool = false
## Ablation: no ground fringe at all. Read by TerrainBlend, which then attaches nothing -- so this
## removes the DRAW CALLS, not merely the shader's cost, and `draw=` on the heartbeat names the
## price of the feature directly.
var ablate_ground_fringe: bool = false
var _pf_max: float = 0.0
var _tf_max: float = 0.0
## `tf=` cut in two by a deferred call planted from the `process_frame` handler: `mq=` is the message
## queue flush, `xf=` is `flush_transform_notifications()` plus the process group's own prologue.
var _mq_usec: int = 0
var _mq_max: float = 0.0
var _xf_max: float = 0.0
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
## Which CLASSES those _physics_process nodes are, and which SCRIPTS drive them. One physics tick was
## measured at 53 ms on this client (fps 2.2 at 60 Hz vs 14-18 at 10 Hz), and the tick contains exactly
## two things: Jolt's step, and these callbacks. A bare count cannot tell a broadphase problem from
## four hundred GDScript callbacks; the script names can.
var _phys_by_class: Dictionary = {}
var _phys_by_script: Dictionary = {}
## Same, for the IDLE callbacks. `nodes with _process=311` was in every log of the 6 fps bug and
## named nobody: the physics side has had a by-script breakdown since the 53 ms tick, and the idle
## side — which is where that bug's whole frame lives — had none.
var _proc_by_class: Dictionary = {}
var _proc_by_script: Dictionary = {}
## Per-script `_process` cost, measured WITHOUT touching a single game script.
##
## `godot(10).log` (2026-09-10): once this autoload was pinned first, `scripts=137-160` on every
## frame — the whole collapse is in the game's own `_process` callbacks, and the census can only say
## WHICH scripts run, not what each costs. So the census hands out priorities: every script that has
## processing nodes at the default priority 0 gets a band (base = _BAND_BASE + k * _BAND_STEP), its
## nodes go to base + 1, and a probe node sits at base to timestamp the start of the band. The cost of
## a script is then probe(k+1) - probe(k), read here on the next frame like every other figure. Two
## fixed probes close the layout: one at -1 (end of the last band; nodes that started processing
## after the census still sit at 0 and land after it) and one at +1 (before the scripts that set
## their own positive priority: sun 100, atmosphere 110, moons 120).
##
## It REORDERS `_process` among priority-0 nodes — which the engine already sorts with an unstable
## sort, so nothing correct can depend on that order. Still a measurement mode: `debug_perf_by_script`.
const _BAND_BASE: int = -500_000
const _BAND_STEP: int = 1_000
var _bands_on: bool = false
var _band_scripts: Array[String] = []
var _band_probes: Array[Node] = []
var _band_t: PackedInt64Array = PackedInt64Array()
var _band_rest_probe: Node = null
var _band_pos_probe: Node = null
var _band_rest_usec: int = 0
var _band_pos_usec: int = 0
var _band_max: Dictionary = {}
## What each band cost in the frame just gone (ms), for the hitch line: the window's worst cannot say
## what a slow frame was made of. Without a band of their own, the nodes born since the census all went
## to `rest0`, and the frames of an arrival (a city's 386 shelves, 2026-11-06) were 24 ms of nobody:
## each node is given its band the frame after it enters (_band_new).
var _band_frame: Dictionary = {}
var _band_new: Array[Node] = []
## Right after this autoload's own _process: from the frame's start to here is what ClientPerf itself cost
## (census slices, VramCensus steps, the heartbeat's prints) — `cperf` in the bands, no longer `unbanded`.
var _band_self_probe: Node = null
var _band_self_usec: int = 0
## After the last band: from here to the -1 probe are the game's nodes at a small negative priority, which
## used to be counted in the last band's time. With the self probe's span to the first band, `prio-`.
var _band_end_probe: Node = null
var _band_end_usec: int = 0
## The previous frame's start, for the self band read a frame late like every other band.
var _prev_frame_start_usec: int = 0

## The physics burst, step by step (see _on_physics_frame). Per frame, then summed per window.
## In one step, in the 4.7 order (main.cpp iteration, scene_tree.cpp physics_process): PhysicsServer sync and
## flush_queries (body/area callbacks), then `physics_frame` (its subscribers, then 3D mouse picking: physics
## raycasts), then every _physics_process, then message queue, timers, tweens, transform flush, navigation,
## and the Jolt step. The last step's Jolt is after the last tail: it is in `pf=`, added to `engine`.
var _phys_head_probe: Node = null
var _pfs_usec: int = 0
var _phead_usec: int = 0
var _pf_steps: int = 0
var _pf_engine_usec: int = 0
var _pf_idle_usec: int = 0
var _pf_sig_usec: int = 0
var _pf_scripts_usec: int = 0
var _pw_steps: int = 0
var _pw_engine_usec: int = 0
var _pw_idle_usec: int = 0
var _pw_sig_usec: int = 0
var _pw_scripts_usec: int = 0
## Physics bands: the _process bands' trick on process_physics_priority, summed over the frame's steps.
var _pband_scripts: Array[String] = []
var _pband_t: PackedInt64Array = PackedInt64Array()
var _pband_end_probe: Node = null
var _pband_end_usec: int = 0
var _pband_rest_usec: int = 0
var _pband_pos_usec: int = 0
var _pband_frame: Dictionary = {}
var _pband_max: Dictionary = {}
var _pband_sum: Dictionary = {}

## CPU ticks per thread id at the last [CPerfT], to turn /proc's totals into a window's share.
var _thread_prev: Dictionary = {}

## GPU passes ([CPerfG]): name -> ms summed over the frames read this window, and how many frames.
var _gpu_sum: Dictionary = {}
var _gpu_frames: int = 0
var _gpu_last_frame: int = -1

## The local player's place at the last heartbeat, in its planet's frame, to say whether it moved.
var _speed_ref: Node3D = null
var _speed_prev: Vector3 = Vector3.ZERO
## Area ablation (debug_no_area_monitoring): how many Area3D this session has silenced, and how many
## are left monitoring. An Area3D costs a broadphase query on EVERY physics step whether or not
## anything moved — which is the shape of cost measured here (53 ms/tick with act=0 pairs=0).
var _areas_ablate: bool = false
var _areas_silenced: int = 0
var _areas_monitoring: int = 0
## Monitoring areas NOT carrying the marker group — the runtime half of the CI check. A non-zero
## count in a shipped build means an area got past review, or was created in code without saying so.
var _areas_undeclared: int = 0
## The one group that declares "this area really must detect". Mirrored by
## tools/check_area_monitoring.py, which enforces it on every .tscn.
const _MONITOR_GROUP: StringName = &"active_monitor"
## WHICH areas monitor, and what they ask for. Silencing 150 of them took this client from 2.6 to
## 30 fps, so each monitoring Area3D costs ~0.1 ms per physics step here — the mark of a broadphase
## query whose candidate set is huge. The fix is not "no areas", it is a narrower `collision_mask`
## on the ones that ask for everything, and only their scripts and masks can say which those are.
var _areas_by_script: Dictionary = {}
var _areas_by_mask: Dictionary = {}
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
## When the next [CPerfV] VRAM census is due (uptime, s; 0 = none). VRAM_AFTER_STATE_S after every
## state change, so the textures of the new state are loaded, then every VRAM_EVERY_S.
var _vram_due: float = 0.0
const VRAM_AFTER_STATE_S: float = 20.0
const VRAM_EVERY_S: float = 300.0
var _vram_every: float = VRAM_EVERY_S
## The census under way, walked VRAM_BUDGET_US per frame (a world is tens of thousands of nodes).
var _vram: VramCensus = null
const VRAM_BUDGET_US: int = 4000
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
## The deep census walks the tree a slice a frame (CENSUS_BUDGET_US), not at once: the whole tree in one
## frame was a 40-50 ms hitch every 4 s of every measured session. [node, planet] still to visit; its
## figures are printed on the heartbeat after the walk ends (_census_ready), the same answer 2 s later.
const CENSUS_BUDGET_US: int = 1000
var _census_stack: Array = []
var _census_ready: bool = false
var _census_due: bool = false
## Filled by the deep census (_visit) every DEEP_EVERY reports.
var _deep: Dictionary = {}
## name -> last value pushed by gauge(). For counts a scope timer cannot express (nodes visited).
var _gauges: Dictionary = {}

func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		set_process(false)
		return
	_boot_ms = Time.get_ticks_msec()
	_mem_avail_boot = int(OS.get_memory_info().get("available", -1))
	# `scripts=` and `tf=` both assume this autoload is the FIRST node whose _process runs. Being an
	# autoload only guarantees TREE order; the process group is sorted by priority with sort_custom,
	# which is NOT stable, so among the ~100 nodes at the default priority 0 this one could land
	# anywhere — and then `scripts=` would time a random SUFFIX of the game's callbacks while `tf=`
	# quietly swallowed the rest. Nothing in five logs proved that was not happening. One line makes
	# the assumption true instead of hopeful.
	process_priority = -1_000_000

	# ALWAYS, whatever debug_perf says. These lines are printed once and describe the machine the
	# game is about to run on; they are worth having in EVERY log, including the ones sent for a bug
	# that has nothing to do with performance, and they cost nothing after boot.
	_print_machine()
	ClientConfig.boot_report()
	# BEFORE _print_boot_detail, which reports `picking=`: run 7 printed `picking=true` on a session
	# that HAD the ablation on, purely because the line was printed first. A boot line that describes
	# a state the run does not have is worse than no line.
	#
	# Tried and EXONERATED on 2026-09-09 (`godot(7).log`): picking off, still 6.0 fps, `pre` still
	# 129-156 ms. `Viewport::_process_picking()` was the best candidate in that window and it is not
	# the cost. Kept because it is one line and it is the only way to re-prove that cheaply.
	# Only `scenes/interactables/gui_3d.gd` uses 3D picking, so switching it off costs the 3D panels.
	if ClientConfig.get_bool("debug_no_picking", false):
		get_viewport().physics_object_picking = false
		print("[CPerf] !! debug_no_picking=true — 3D object picking is OFF on the root viewport."
				+ " The gui_3d interactable panels will not respond to the mouse.")
	# Read here rather than behind `enabled`, because planet_body reads it on every physics tick and
	# an ablation that only works when the heartbeat is on is an ablation nobody can run cleanly.
	ablate_planet_spin = ClientConfig.get_bool("debug_no_planet_spin", false)
	if ablate_planet_spin:
		print("[CPerf] !! debug_no_planet_spin=true — planets do not rotate. THE WORLD IS WRONG"
				+ " (no day/night motion, carried bodies are not counter-rotated): measurement mode.")
	# Read here rather than behind `enabled`, for the same reason as the spin above: TerrainBlend
	# reads it when a prop settles, which happens long before anyone thinks to turn the heartbeat on.
	ablate_ground_fringe = ClientConfig.get_bool("debug_no_terrain_blend", false)
	if ablate_ground_fringe:
		print("[CPerf] !! debug_no_terrain_blend=true — objects meet the ground on a hard cut line:"
				+ " measurement mode, not a fix.")
	# Cost dial of planet_surface.gdshader (the hex-tiled corundum ground), a shader global so no
	# material has to be swapped: 2 = full, 1 = hex albedo and normal only, 0 = plain triplanar texture(). A
	# RX 5700 XT spent 30 ms of GPU per frame on the full version where a RTX 3080 spent 3, and
	# textureGrad + anisotropic sampling is the suspected AMD-specific cost; 0 is the same shader on
	# the sampler's fast path, so a player's rgpu at 0 versus 2 names it in one session.
	var hex_q: int = clampi(ClientConfig.get_int("debug_hex_quality", 2), 0, 2)
	if hex_q != 2:
		RenderingServer.global_shader_parameter_set("planet_hex_quality", hex_q)
		print("[CPerf] !! debug_hex_quality=%d — planet ground hex tiling reduced (%s)." % [hex_q,
				"hex albedo and normal, no parallax, plain roughness" if hex_q == 1
				else "NO hex tiling, plain triplanar: repetition is visible"])
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
	_vram_every = maxf(10.0, ClientConfig.get_float("debug_perf_vram_every", VRAM_EVERY_S))
	_deep_every = maxi(1, ClientConfig.get_int("debug_perf_deep_every", DEEP_EVERY))
	# Bisection switch, in the same family as the debug_rocks_* ones: run the simulation at a lower
	# tick rate for one measurement. Nothing else in the client separates "the frame is long because of
	# physics" from "the frame is long because of _process" — 95% of the frame currently sits in no
	# scope at all, rendering and networking have both been exonerated by a 5x drop that moved the
	# framerate not at all, and this is the one-line experiment that halves what is left. It CHANGES
	# THE SIMULATION (movement gets coarse, contacts get sloppy): measure, read, put it back to 0.
	_areas_ablate = ClientConfig.get_bool("debug_no_area_monitoring", false)
	if _areas_ablate:
		print("[CPerf] !! debug_no_area_monitoring=true — every Area3D that is NOT in the"
				+ " `active_monitor` group will be silenced as the census walks the tree."
				+ " INTERACTIONS MAY BREAK: this is a measurement mode, not a fix.")
	var _phz: int = ClientConfig.get_int("debug_physics_hz", 0)
	if _phz > 0:
		var _was: int = Engine.physics_ticks_per_second
		Engine.physics_ticks_per_second = clampi(_phz, 1, 240)
		# Parenthesised: `%` binds tighter than `+`, so without them the arguments would be applied to
		# the second literal (which has no placeholders) instead of the whole message.
		print(("[CPerf] !! debug_physics_hz=%d — physics tick forced from %d Hz to %d Hz."
				+ " THIS IS A MEASUREMENT MODE, not a fix: the simulation is degraded.")
				% [_phz, _was, Engine.physics_ticks_per_second])
	# The two probes that split `proc=` (see _scripts_usec). Neither exists unless the heartbeat is
	# on, so a normal player pays nothing for either.
	_tail = _TailProbe.new()
	_tail.name = "CPerfTail"
	_tail.tick = _tail_tick
	# process_priority orders the WHOLE tree, not just siblings: the highest value is called last, so
	# this lands after every game node's _process. Left on PROCESS_MODE_INHERIT deliberately — it
	# must go quiet in exactly the frames this autoload does, or a paused tree would report the pause
	# as script time.
	_tail.process_priority = 1_000_000
	_tail.phys_tick = _phys_tail_tick
	_tail.process_physics_priority = 1_000_000
	add_child(_tail)
	# The other end of each physics step's scripts: the first _physics_process of the step.
	_phys_head_probe = _phys_probe(-1_000_000, _phys_head_tick)
	# First subscriber (an autoload's _ready): its stamp is the start of the signal, before the game's own
	# handlers and the mouse picking, which then fall in `sig+pick`.
	get_tree().physics_frame.connect(_on_physics_frame)
	PerfTasks.on = true
	PerfTasks.take_window(Time.get_ticks_usec())
	_bands_on = ClientConfig.get_bool("debug_perf_by_script", true)
	if _bands_on:
		_band_self_probe = _band_probe(-999_999, func() -> void: _band_self_usec = Time.get_ticks_usec())
		_band_end_probe = _band_probe(_BAND_BASE, func() -> void: _band_end_usec = Time.get_ticks_usec())
		_band_rest_probe = _band_probe(-1, _band_rest_tick)
		_band_pos_probe = _band_probe(1, _band_pos_tick)
		_pband_end_probe = _phys_probe(_BAND_BASE, func() -> void: _pband_end_usec = Time.get_ticks_usec())
		_phys_probe(-1, func() -> void: _pband_rest_usec = Time.get_ticks_usec())
		_phys_probe(1, func() -> void: _pband_pos_usec = Time.get_ticks_usec())
		get_tree().node_added.connect(_on_node_added_band)
		print("[CPerf] !! debug_perf_by_script=true — _process and _physics_process order among priority-0"
			+ " nodes is regrouped by script so each script's cost can be timed ([CPerf%] / [CPerfP] lines).")
	# Connected from an autoload's _ready, so this handler runs near the FRONT of the signal's
	# subscriber list: `tf=` then contains the game's own `process_frame` work rather than hiding it.
	get_tree().process_frame.connect(_on_tree_process_frame)
	# The renderer's own timers. The GPU figure arrives a frame or two late (it is a timestamp query
	# read back, not a wall clock), which is fine for a cost that has been steady for five minutes.
	_viewport_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)
	# Emitted on the MAIN thread, immediately around RenderingServer::draw(). Bound here rather than
	# read from a monitor because no monitor reports the main thread's wait on the render thread.
	RenderingServer.frame_pre_draw.connect(_on_frame_pre_draw)
	RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
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


## The command line as the log may show it: the value of every secret flag replaced by `xxxxx`.
## The launcher passes the player's JWT as `--token=<jwt>`, and players paste this log in public
## Discord channels to report a bug — anyone holding the token can play as them until it expires.
static func redacted_args(args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for arg: String in args:
		var eq := arg.find("=")
		var flag := arg.substr(0, eq).to_lower() if eq > 0 else ""
		if flag.begins_with("--") and ("token" in flag or "secret" in flag or "password" in flag):
			out.append(arg.substr(0, eq + 1) + "xxxxx")
		else:
			out.append(arg)
	return out


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
	# A build tagged `debug` runs with checks a release build does not have — it has been mistaken
	# for slowness before.
	var tags: PackedStringArray = []
	for tag: String in ["editor", "template", "debug", "release", "standalone", "dedicated_server",
			"windows", "linuxbsd", "macos", "web", "x86_64", "arm64", "mono", "double"]:
		if OS.has_feature(tag):
			tags.append(tag)
	# The adapter NAME is already on the machine line; vendor/type/api are not, and "is this the
	# integrated GPU?" (type) plus the API version is most of a driver diagnosis.
	print("[CPerf] features=%s | args=%s | session=%s/%s | gpu_vendor=%s type=%d api=%s" % [
		",".join(tags),
		" ".join(redacted_args(OS.get_cmdline_args())),
		OS.get_environment("XDG_SESSION_TYPE"), OS.get_environment("WAYLAND_DISPLAY"),
		RenderingServer.get_video_adapter_vendor(),
		RenderingServer.get_video_adapter_type(), RenderingServer.get_video_adapter_api_version(),
	])

	# Every screen, not just the current one: a laptop rendering onto a 4K external at 60 Hz while
	# the game thinks it is on the built-in panel is a classic source of "my fps is half yours".
	#
	# `at=` is the screen's ORIGIN on the virtual desktop, and it is not decoration: `window_get_position`
	# is absolute, so without it a window at x=720 on a machine with a 1760-wide screen #0 reads as
	# straddling two monitors — which is exactly the false lead we chased for three days on the 6 fps
	# report, until a screenshot showed the wide screen sits FIRST and the window is entirely inside it.
	var screens: PackedStringArray = []
	for i: int in DisplayServer.get_screen_count():
		screens.append("#%d %s at%s @%.0fHz dpi=%d scale=%.2f" % [
			i, str(DisplayServer.screen_get_size(i)), str(DisplayServer.screen_get_position(i)),
			DisplayServer.screen_get_refresh_rate(i),
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
			+ " picking=%s"
		) % [
			RenderingServer.get_current_rendering_method(),
			str(vp.get_visible_rect().size),
			int(vp.scaling_3d_mode), vp.scaling_3d_scale, int(vp.msaa_3d), int(vp.screen_space_aa),
			vp.use_taa, vp.use_debanding, int(vp.vrs_mode),
			vp.positional_shadow_atlas_size,
			# The sun's atlas has no getter: the setting is what RenderApplier gave the engine.
			str(SettingsManager.render.effective("shadow_sun_res")),
			str(ProjectSettings.get_setting("rendering/occlusion_culling/use_occlusion_culling", "?")),
			str(int(vp.anisotropic_filtering_level)),
			str(vp.physics_object_picking),
		])
	# Which preset that is, what this GPU was guessed to be, and every option as it applies.
	print("[CPerf] graphics %s" % SettingsManager.render.describe())

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
	_vram_due = _uptime() + VRAM_AFTER_STATE_S
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
	# Start of THIS frame's callbacks, for the tail probe at the other end of them.
	_prev_frame_start_usec = _frame_start_usec
	_frame_start_usec = now
	if prev == 0:
		return
	var ms: float = float(now - prev) / 1000.0

	_frames += 1
	if not _census_stack.is_empty():
		_census_step()
	if _vram != null and _vram.step(VRAM_BUDGET_US):
		for line: String in _vram.lines():
			print(line)
		_vram = null
	var proc_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	# Everything below reads the frame that just ENDED, like _frame_usec and `ms` itself: the tail
	# probe ran at the end of it, and the viewport timers hold the frame the renderer last finished.
	var scripts_ms: float = float(_scripts_usec) / 1000.0
	var rcpu_ms: float = RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
	var rgpu_ms: float = RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
	_proc_max = maxf(_proc_max, proc_ms)
	_phys_max = maxf(_phys_max, phys_ms)
	_scripts_max = maxf(_scripts_max, scripts_ms)
	_rcpu_max = maxf(_rcpu_max, rcpu_ms)
	_rgpu_max = maxf(_rgpu_max, rgpu_ms)
	# The tail of the SAME frame: the tail probe, then draw()'s two signals, all before this call.
	var sync_ms: float = 0.0
	var draw_ms: float = 0.0
	if _tail_usec > 0 and _predraw_usec > _tail_usec:
		sync_ms = float(_predraw_usec - _tail_usec) / 1000.0
	if _postdraw_usec > _predraw_usec:
		draw_ms = float(_postdraw_usec - _predraw_usec) / 1000.0
	# Render-thread work OUTSIDE any viewport: dirty instances, AABBs, culling structures.
	var setup_ms: float = RenderingServer.get_frame_setup_time_cpu()
	_sync_max = maxf(_sync_max, sync_ms)
	_draw_max = maxf(_draw_max, draw_ms)
	_setup_max = maxf(_setup_max, setup_ms)
	# From the end of the previous frame's draw to the start of this one's callbacks.
	var gap_ms: float = 0.0
	var pre_ms: float = 0.0
	if _postdraw_usec > 0 and now > _postdraw_usec:
		gap_ms = float(now - _postdraw_usec) / 1000.0
		# A frame can run zero physics steps, and then the physics tail is stale and says nothing.
		pre_ms = float(now - _phys_tail_usec) / 1000.0 if _phys_tail_usec > _postdraw_usec else gap_ms
	_gap_max = maxf(_gap_max, gap_ms)
	_pre_max = maxf(_pre_max, pre_ms)
	var pf_ms: float = 0.0
	var tf_ms: float = 0.0
	var mq_ms: float = 0.0
	var xf_ms: float = 0.0
	if _pframe_usec > _phys_tail_usec and now > _pframe_usec:
		pf_ms = float(_pframe_usec - _phys_tail_usec) / 1000.0
		tf_ms = float(now - _pframe_usec) / 1000.0
		if _mq_usec > _pframe_usec and now > _mq_usec:
			mq_ms = float(_mq_usec - _pframe_usec) / 1000.0
			xf_ms = float(now - _mq_usec) / 1000.0
	_pf_max = maxf(_pf_max, pf_ms)
	_tf_max = maxf(_tf_max, tf_ms)
	_mq_max = maxf(_mq_max, mq_ms)
	_xf_max = maxf(_xf_max, xf_ms)
	# The physics burst just gone, step by step. The last step's Jolt sits in `pf=` (after its tail).
	var psteps: int = _pf_steps
	var pscripts_ms: float = float(_pf_scripts_usec) / 1000.0
	var psig_ms: float = float(_pf_sig_usec) / 1000.0
	var pengine_ms: float = float(_pf_engine_usec) / 1000.0 + (pf_ms if psteps > 0 else 0.0)
	var pidle_ms: float = float(_pf_idle_usec) / 1000.0
	_pw_idle_usec += _pf_idle_usec
	_pf_idle_usec = 0
	_pw_steps += psteps
	_pw_scripts_usec += _pf_scripts_usec
	_pw_sig_usec += _pf_sig_usec
	_pw_engine_usec += int(pengine_ms * 1000.0)
	_pf_steps = 0
	_pf_scripts_usec = 0
	_pf_sig_usec = 0
	_pf_engine_usec = 0
	var pbands: String = bands_line(_pband_frame, 1.0)
	for name_k: String in _pband_frame:
		_pband_max[name_k] = maxf(float(_pband_max.get(name_k, 0.0)), float(_pband_frame[name_k]))
		_pband_sum[name_k] = float(_pband_sum.get(name_k, 0.0)) + float(_pband_frame[name_k])
	_pband_frame.clear()
	_gpu_collect()
	if _bands_on:
		_band_collect()
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
				+ " | scripts=%.0f rcpu=%.1f rgpu=%.1f setup=%.1f sync=%.0f rsdraw=%.0f"
				+ " gap=%.0f pre=%.0f (pf=%.0f tf=%.0f mq=%.0f xf=%.0f) ms"
				+ " | idle=%.1f steps=%d pscripts=%.1f sig+pick=%.1f pengine=%.1f ms pbands: %s"
				+ " | nodes=%d%+d | %s | bands: %s | draw=%d obj=%d act=%d pairs=%d mem=%s vram=%s"
			) % [
				_clock(), _uptime(), ms, Engine.get_frames_drawn(),
				proc_ms, phys_ms, Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0,
				scripts_ms, rcpu_ms, rgpu_ms, setup_ms, sync_ms, draw_ms, gap_ms, pre_ms,
				pf_ms, tf_ms, mq_ms, xf_ms,
				pidle_ms, psteps, pscripts_ms, psig_ms, pengine_ms, pbands,
				nodes, nodes - _prev_nodes,
				_frame_breakdown(),
				_bands_of_frame(scripts_ms),
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
	_scripts_max = 0.0
	_rcpu_max = 0.0
	_rgpu_max = 0.0
	_sync_max = 0.0
	_draw_max = 0.0
	_setup_max = 0.0
	_gap_max = 0.0
	_pre_max = 0.0
	_pf_max = 0.0
	_tf_max = 0.0
	_mq_max = 0.0
	_xf_max = 0.0
	_band_max.clear()
	_pband_max.clear()
	_pband_sum.clear()
	_pw_steps = 0
	_pw_scripts_usec = 0
	_pw_sig_usec = 0
	_pw_engine_usec = 0
	_pw_idle_usec = 0
	_gpu_sum.clear()
	_gpu_frames = 0
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
	for i: int in PerfMath.PIPE_MONITORS.size():
		var v: int = int(Performance.get_monitor(PerfMath.PIPE_MONITORS[i]))
		pipe_now.append(v)
		pipe_delta.append(str(v - _pipe_prev[i]))
	_pipe_prev = pipe_now

	print((
		"[CPerf] %s up=%.1fs | fps=%.1f worst=%.0fms@%.1fs hitches=%d"
		+ " | win=%.1fs proc<=%.0f phys<=%.0f@%.0f/%dHz nav=%.2f ms"
		+ " | scripts<=%.0f rcpu<=%.1f rgpu<=%.1f setup<=%.1f sync<=%.0f rsdraw<=%.0f"
		+ " gap<=%.0f pre<=%.0f (pf<=%.0f tf<=%.0f mq<=%.0f xf<=%.0f) ms"
		+ " | draw=%d obj=%d prim=%s | 3d act=%d pairs=%d isl=%d"
		+ " | nav maps=%d reg=%d poly=%d | nodes=%d orphan=%d res=%d"
		+ " | mem=%s vram=%s | pipe+=%s"
	) % [
		_clock(), _uptime(),
		fps, _worst_ms, _worst_at, _hitches,
		window, _proc_max,
		_phys_max, phys_hz, Engine.physics_ticks_per_second,
		Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0,
		_scripts_max, _rcpu_max, _rgpu_max, _setup_max, _sync_max, _draw_max,
		_gap_max, _pre_max, _pf_max, _tf_max, _mq_max, _xf_max,
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
	parts.append_array(_motion_context(window))
	parts.append_array(_host_cpu_context(window))
	if not parts.is_empty():
		print("[CPerf+] %s | %s" % [_clock(), " | ".join(parts)])

	_print_frame_signal_subs()
	_print_bands()
	_print_physics(window)
	_print_threads(window)
	print("[CPerfW] %s workers %s" % [_clock(), PerfTasks.line(PerfTasks.take_window(Time.get_ticks_usec()), window)])
	_print_gpu()
	_report_extras(fps)
	if _vram_due > 0.0 and _uptime() >= _vram_due and _vram == null:
		_vram_due = _uptime() + _vram_every
		_vram = VramCensus.new()
		_vram.start(get_tree())
	_census_ready = false
	if _census_due and _census_stack.is_empty():
		_census_due = false
		_census_start()
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
	if _census_ready and not _classes.is_empty():
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
		_clock(), n, PerfMath.percentile(ordered, 0.50), PerfMath.percentile(ordered, 0.90),
		PerfMath.percentile(ordered, 0.99), PerfMath.percentile(ordered, 1.0),
		buckets[0], buckets[1], buckets[2], buckets[3], buckets[4], buckets[5], buckets[6],
		100.0 * stalled_ms / maxf(total_ms, 0.001)])


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
	# Second line: who those _physics_process nodes are. Ranked, because the tail is never the story.
	print("[CPerf*] %s _physics_process by script: %s | by class: %s" % [
		_clock(), _top_pairs(_phys_by_script, 8), _top_pairs(_phys_by_class, 8)])
	# And the idle half, which `scripts=` on the heartbeat gives a millisecond figure to.
	print("[CPerf*] %s _process by script: %s | by class: %s" % [
		_clock(), _top_pairs(_proc_by_script, 8), _top_pairs(_proc_by_class, 8)])
	# Third line: the monitoring areas, which measured out as this client's single biggest cost.
	print("[CPerf*] %s monitoring Area3D by script: %s | by collision_mask: %s" % [
		_clock(), _top_pairs(_areas_by_script, 8), _top_pairs(_areas_by_mask, 8)])


## "name=count name=count" for the busiest entries of a census dictionary.
func _top_pairs(counts: Dictionary, top: int) -> String:
	var keys: Array = counts.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return int(counts[a]) > int(counts[b]))
	var parts: PackedStringArray = []
	for i: int in mini(top, keys.size()):
		parts.append("%s=%d" % [str(keys[i]), int(counts[keys[i]])])
	return " ".join(parts) if not parts.is_empty() else "none"


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


## The orchestrator's agent can be freed on disconnect while the autoload keeps its reference.
func agent_valid() -> bool:
	return "network_agent" in NetworkOrchestrator and is_instance_valid(NetworkOrchestrator.network_agent)


## Game-specific context: where the local player is, in which frame, and how big the tree hanging
## off each planet has grown. The last one is the cost driver of planet_body's 3 Hz refresh, and it
## is the number that a zone duplication silently doubles.
## Is the CLIENT being starved by the rest of the machine? A local test runs the game server (30 NPC
## brains, nav bakes) and the editor on the same box, and no in-process scope can tell "our frame is
## slow" from "we are not being scheduled". Linux only (/proc): `cpu=` is this process's CPU time
## over the window as a share of ONE core (a healthy client runs at 100-300 %), `load=` the 1-minute
## load average against the core count (above 1.0 the runnable threads outnumber the cores).
var _cpu_prev_ticks: int = -1

func _host_cpu_context(window: float) -> PackedStringArray:
	var out: PackedStringArray = []
	if not OS.has_feature("linuxbsd"):
		return out
	var stat: FileAccess = FileAccess.open("/proc/self/stat", FileAccess.READ)
	if stat == null:
		return out
	# Fields after the parenthesised comm: utime then stime, in clock ticks (100 Hz). Read by line:
	# /proc files report a zero length, so get_as_text() comes back empty.
	var rest: String = stat.get_line().get_slice(") ", 1)
	var fields: PackedStringArray = rest.split(" ", false)
	if fields.size() > 13:
		var ticks: int = int(fields[11]) + int(fields[12])
		if _cpu_prev_ticks >= 0:
			out.append("cpu=%.0f%%" % (float(ticks - _cpu_prev_ticks) / 100.0 / window * 100.0))
		_cpu_prev_ticks = ticks
	var load: FileAccess = FileAccess.open("/proc/loadavg", FileAccess.READ)
	if load != null:
		out.append("load=%s/%d" % [load.get_line().get_slice(" ", 0), OS.get_processor_count()])
	return out

## Whether the local player moved this window, and how fast (m/s, in its planet's frame: the planet spins,
## so a global position would move with it). "It drops when I walk" is a claim about these windows.
func _motion_context(window: float) -> PackedStringArray:
	var out: PackedStringArray = []
	var agent: Node = NetworkOrchestrator.network_agent if agent_valid() else null
	var me_ref: Variant = agent.player_entity if agent != null and "player_entity" in agent else null
	var me: Node3D = me_ref as Node3D if is_instance_valid(me_ref) and me_ref is Node3D else null
	if me == null or not me.is_inside_tree():
		_speed_ref = null
		return out
	var ref: Node3D = me.get_parent() as Node3D
	var up: Node = me.get_parent()
	while up != null:
		if up.is_in_group(PLANET_GROUP) and up is Node3D:
			ref = up as Node3D
			break
		up = up.get_parent()
	var here: Vector3 = ref.to_local(me.global_position) if ref != null else me.global_position
	if ref != null and ref == _speed_ref:
		out.append("speed=%.1fm/s" % (here.distance_to(_speed_prev) / maxf(window, 0.001)))
	_speed_ref = ref
	_speed_prev = here
	return out


## The group a thread of this process belongs to, from its /proc name: `main` for the main thread, the
## name without its number otherwise ("WorkerThread 3" -> "WorkerThread"); a thread the engine did not
## name carries the executable's name, [param main_comm], and is `unnamed`.
static func thread_group(comm: String, tid: int, pid: int, main_comm: String) -> String:
	if tid == pid:
		return "main"
	if comm == main_comm:
		return "unnamed"
	var name_k: String = comm.strip_edges()
	while not name_k.is_empty() and (name_k[-1] in "0123456789#"):
		name_k = name_k.left(-1)
	return name_k.strip_edges() if not name_k.strip_edges().is_empty() else comm


## CPU per thread group over the window, a share of ONE core (Linux, /proc/self/task). `cpu=` on [CPerf+]
## said 6.5-7.8 cores at the village (2026-11-27) and nothing said whose; this says which threads,
## [CPerfW] which tasks on the WorkerThread ones.
func _print_threads(window: float) -> void:
	if not OS.has_feature("linuxbsd"):
		return
	var pid: int = OS.get_process_id()
	var main_comm: String = ""
	var rows: Array = []  # [tid, comm, ticks]
	for tid_s: String in DirAccess.get_directories_at("/proc/self/task"):
		var f: FileAccess = FileAccess.open("/proc/self/task/%s/stat" % tid_s, FileAccess.READ)
		if f == null:
			continue
		var stat: String = f.get_line()
		var open_at: int = stat.find("(")
		var close_at: int = stat.rfind(")")
		if open_at < 0 or close_at < open_at:
			continue
		var fields: PackedStringArray = stat.substr(close_at + 2).split(" ", false)
		if fields.size() < 13:
			continue
		var comm: String = stat.substr(open_at + 1, close_at - open_at - 1)
		if int(tid_s) == pid:
			main_comm = comm
		rows.append([int(tid_s), comm, int(fields[11]) + int(fields[12])])
	var first: bool = _thread_prev.is_empty()
	var now_prev: Dictionary = {}
	var groups: Dictionary = {}
	var counts: Dictionary = {}
	var singles: Array = []
	for row: Array in rows:
		var tid: int = row[0]
		var ticks: int = row[2]
		now_prev[tid] = ticks
		if first:
			continue
		# A thread born in the window counts all it ran: it ran it in the window.
		var pct: float = float(ticks - int(_thread_prev.get(tid, 0))) / maxf(window, 0.001)
		var group: String = thread_group(row[1], tid, pid, main_comm)
		groups[group] = float(groups.get(group, 0.0)) + pct
		counts[group] = int(counts.get(group, 0)) + 1
		singles.append([pct, "%s(%d)" % [row[1], tid]])
	_thread_prev = now_prev
	if first:
		return
	var names: Array = groups.keys()
	names.sort_custom(func(a: String, b: String) -> bool: return float(groups[a]) > float(groups[b]))
	var total: float = 0.0
	var parts: PackedStringArray = []
	for g: String in names:
		total += float(groups[g])
		if float(groups[g]) >= 1.0:
			parts.append("%s=%.0f%%(%d)" % [g, float(groups[g]), int(counts[g])])
	singles.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
	var top: PackedStringArray = []
	for s: Array in singles.slice(0, 5):
		if float(s[0]) >= 5.0:
			top.append("%s=%.0f%%" % [s[1], float(s[0])])
	print("[CPerfT] %s threads cpu=%.0f%% | %s | busiest: %s" % [
		_clock(), total, " ".join(parts), " ".join(top) if not top.is_empty() else "none"])


func _world_context() -> PackedStringArray:
	var out: PackedStringArray = []
	var tree: SceneTree = get_tree()
	if tree == null:
		return out

	# The local player is the one node whose distance from the world origin sets the f32 quantisation
	# every other physics number in this log inherits. NetworkOrchestrator owns it; nothing else here
	# depends on the network being up, so a null agent just drops the field.
	var agent: Node = NetworkOrchestrator.network_agent if agent_valid() else null
	# UNTYPED on purpose: player_entity is a dangling reference for the few frames between the old
	# player being freed (respawn, zone change) and the new one being assigned, and assigning a freed
	# instance to a typed Node var raises "Trying to assign invalid previously freed instance".
	var me_ref: Variant = agent.player_entity if agent != null and "player_entity" in agent else null
	var me: Node = me_ref if is_instance_valid(me_ref) and me_ref is Node else null
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
			# A planet or a zone streams in after the state change: census again once it is there.
			_vram_due = _uptime() + VRAM_AFTER_STATE_S

	# Deep counts only every DEEP_EVERY reports: ONE recursive walk of the whole tree, which is the
	# same order of work as the 3 Hz spin refresh does anyway — but doing it 30x/min would not be.
	if _force_deep or _reports % _deep_every == 1:
		_force_deep = false
		_census_due = true  # started once this heartbeat has printed what the last walk found
	if _census_ready:
		out.append("areas_monitoring=%d" % _areas_monitoring)
		if _areas_undeclared > 0:
			out.append("areas_UNDECLARED=%d" % _areas_undeclared)
		if _areas_ablate:
			out.append("areas_silenced=%d" % _areas_silenced)
		for k: String in _deep.keys():
			out.append("%s=%d" % [k, _deep[k]])
	return out


## A new census: the counts from zero, the walk from the root (_census_step does it, a slice a frame).
func _census_start() -> void:
	_deep.clear()
	_classes.clear()
	_procs = 0
	_phys_procs = 0
	_phys_by_class.clear()
	_phys_by_script.clear()
	_proc_by_class.clear()
	_proc_by_script.clear()
	_areas_monitoring = 0
	_areas_undeclared = 0
	_areas_by_script.clear()
	_areas_by_mask.clear()
	_census_stack = [[get_tree().root, ""]]


## Visit nodes of the census for CENSUS_BUDGET_US; a node freed since it was queued is skipped.
func _census_step() -> void:
	var deadline: int = Time.get_ticks_usec() + CENSUS_BUDGET_US
	while not _census_stack.is_empty() and Time.get_ticks_usec() < deadline:
		var entry: Array = _census_stack.pop_back()
		if is_instance_valid(entry[0]):
			_visit(entry[0], entry[1])
	if _census_stack.is_empty():
		_census_ready = true


## One node of the census. `planet` is the name of the Planet ancestor we are under, if any, so each
## planet's subtree size is reported separately — that subtree is exactly what planet_body's spin
## refresh walks 3x/s, and exactly what a duplicated zone silently doubles.
func _visit(node: Node, planet: String) -> void:
	# One extra dictionary bump and two flag reads per node. It doubles the cost of a walk that
	# already runs at most every few seconds, and it is the difference between knowing HOW MANY nodes
	# there are and knowing WHICH ones.
	var cls: String = node.get_class()
	_classes[cls] = int(_classes.get(cls, 0)) + 1
	if node.is_processing():
		_procs += 1
		_proc_by_class[cls] = int(_proc_by_class.get(cls, 0)) + 1
		var pscr: Script = node.get_script()
		var pname: String = pscr.resource_path.get_file() if pscr != null else "<no script>"
		_proc_by_script[pname] = int(_proc_by_script.get(pname, 0)) + 1
	_band_node(node)
	if node.is_physics_processing():
		_phys_procs += 1
		_phys_by_class[cls] = int(_phys_by_class.get(cls, 0)) + 1
		# The script is what actually costs: two nodes of the same class can run very different
		# callbacks, and a node with no script at all is pure engine work.
		var scr: Script = node.get_script()
		var sname: String = scr.resource_path.get_file() if scr != null else "<no script>"
		_phys_by_script[sname] = int(_phys_by_script.get(sname, 0)) + 1
	# Area census + optional ablation, on the same walk. PlanetGravity is spared: without it the player
	# loses gravity and starts falling, which would make the very thing being measured move.
	if node is Area3D:
		var area := node as Area3D
		if area.monitoring:
			# Census BEFORE any ablation, or the switch would hide the very list it exists to produce.
			var ascr: Script = area.get_script()
			var an: String = ascr.resource_path.get_file() if ascr != null else area.name
			_areas_by_script[an] = int(_areas_by_script.get(an, 0)) + 1
			var mk: String = "mask=%d" % area.collision_mask
			_areas_by_mask[mk] = int(_areas_by_mask.get(mk, 0)) + 1
			# An area monitoring WITHOUT the marker is the bug tools/check_area_monitoring.py
			# catches in scenes — counted here too, because a live tree also holds areas created
			# in code, which no static check of .tscn files can ever see.
			if not area.is_in_group(_MONITOR_GROUP):
				_areas_undeclared += 1
			# The ablation spares declared monitors, so the switch answers "what do the areas we
			# did NOT intend cost?" rather than breaking gravity along with everything else.
			if _areas_ablate and not area.is_in_group(_MONITOR_GROUP):
				area.monitoring = false
				_areas_silenced += 1
			else:
				_areas_monitoring += 1
	if node.is_in_group(PLANET_GROUP):
		planet = node.name
	elif planet != "":
		_bump("subtree:" + planet)
	if node is NavigationRegion3D:
		_bump("navregions")
	elif node is RigidBody3D:
		_bump("rigidbodies")
	elif node is Area3D:
		_bump("areas")
	# CSG, because a CSG node that is NOT the root of its own tree rebuilds the WHOLE root brush on
	# every transform change, and it does it through `call_deferred` — so the cost lands in the
	# message queue flush inside `tf=`, where no probe has ever looked, while `msgbuf` stays at a few
	# KiB because a deferred call is small to STORE and expensive to RUN.
	if node is CSGShape3D:
		_bump("csg")
		if node.get_parent() is CSGShape3D:
			_bump("csg_child")
	if node.is_in_group("cargo_depots"):
		_bump("cargo_depots")
	elif node.is_in_group("miningrock"):
		_bump("miningrocks")
	for c: Node in node.get_children():
		_census_stack.append([c, planet])


func _bump(key: String) -> void:
	_deep[key] = int(_deep.get(key, 0)) + 1


func _uptime() -> float:
	return float(Time.get_ticks_msec() - _boot_ms) / 1000.0


func _clock() -> String:
	return Time.get_time_string_from_system()


## The other end of a frame's script callbacks.
##
## Nothing in the engine reports "time spent in _process": TIME_PROCESS is the whole idle step,
## renderer included, and every attempt to read a 6 fps log stopped at that ambiguity. A node with
## the highest possible process_priority runs after every other node's _process, so the gap between
## this autoload (first, being an autoload) and this probe (last) IS the game's script time — no
## engine patch, no profiler, and it costs one subtraction a frame.
##
## It reports into the parent rather than keeping its own state so the number is read where every
## other one is, on the frame after, next to `proc=` and the renderer's own figures.
class _TailProbe extends Node:
	## A Callable, not the parent node: a statically typed `Node` cannot be asked for a method the
	## class does not declare, and dropping the type to get one back would give up the only checking
	## GDScript does here.
	var tick: Callable = Callable()
	## Same trick on the physics side: the last _physics_process of the last step of the burst.
	var phys_tick: Callable = Callable()

	func _process(_delta: float) -> void:
		if not tick.is_null():
			tick.call()

	func _physics_process(_delta: float) -> void:
		if not phys_tick.is_null():
			phys_tick.call()


## Called by _TailProbe once every frame, after every other _process in the game.
func _tail_tick() -> void:
	_tail_usec = Time.get_ticks_usec()
	_scripts_usec = _tail_usec - _frame_start_usec


## End of the LAST physics step of the burst, so the frame's dead time can be cut in two: the
## physics burst itself, and what SceneTree does before it calls a single _process.
func _phys_tail_tick() -> void:
	_phys_tail_usec = Time.get_ticks_usec()
	_pf_steps += 1
	if _phead_usec > 0:
		_pf_scripts_usec += _phys_tail_usec - _phead_usec
	if _bands_on:
		_pband_collect_step()


## `physics_frame`, first subscriber. From the previous step's tail to here is the engine's part: that step's
## flushes, timers, navigation and Jolt step, then this step's sync and collision callbacks. For a frame's
## first step the span starts at the last draw and holds what is not physics at all — the frame cap's sleep,
## the OS events, the input callbacks — so it is `idle`, not `engine` (with that step's sync, small).
func _on_physics_frame() -> void:
	var now: int = Time.get_ticks_usec()
	# The frame's end: the draw, or the last _process where nothing draws (headless emits no post_draw).
	var frame_end: int = maxi(_postdraw_usec, _tail_usec)
	if _phys_tail_usec > frame_end:
		_pf_engine_usec += now - _phys_tail_usec
	elif frame_end > 0 and now > frame_end:
		_pf_idle_usec += now - frame_end
	_pfs_usec = now


## First _physics_process of the step: the signal's other subscribers and the 3D picking lie before it.
func _phys_head_tick() -> void:
	_phead_usec = Time.get_ticks_usec()
	if _pfs_usec > 0 and _phead_usec > _pfs_usec:
		_pf_sig_usec += _phead_usec - _pfs_usec


## A probe on the physics side only, at physics priority [param priority].
func _phys_probe(priority: int, tick: Callable) -> Node:
	var probe: _TailProbe = _TailProbe.new()
	probe.name = "CPerfPhys%d" % priority
	probe.phys_tick = tick
	probe.process_physics_priority = priority
	add_child(probe)
	probe.set_process(false)
	return probe


## One step's physics bands, added to the frame's (_pband_frame, ms). Same layout as _band_collect:
## band k ends where band k+1 starts, the last at the end probe; `prio-` is head -> first band plus end ->
## -1 probe; `rest0`, `prio+` as there.
func _pband_collect_step() -> void:
	var n: int = _pband_scripts.size()
	var add := func(key: String, t0: int, t1: int) -> void:
		if t0 > 0 and t1 >= t0:
			_pband_frame[key] = float(_pband_frame.get(key, 0.0)) + float(t1 - t0) / 1000.0
	for k: int in n:
		add.call(_pband_scripts[k], _pband_t[k], _pband_t[k + 1] if k + 1 < n else _pband_end_usec)
	var first: int = _pband_t[0] if n > 0 else _pband_end_usec
	var neg: float = 0.0
	if _phead_usec > 0 and first >= _phead_usec:
		neg += float(first - _phead_usec) / 1000.0
	if _pband_end_usec > 0 and _pband_rest_usec >= _pband_end_usec:
		neg += float(_pband_rest_usec - _pband_end_usec) / 1000.0
	if neg > 0.0:
		_pband_frame["prio-"] = float(_pband_frame.get("prio-", 0.0)) + neg
	add.call("rest0", _pband_rest_usec, _pband_pos_usec)
	add.call("prio+", _pband_pos_usec, _phys_tail_usec)


## The GPU time of the renderer's passes in one captured frame, from its timestamps ([param names], their
## GPU times in ns): pass name -> ms, the time from a stamp to the next put to the first one's name, as the
## engine's own GPU PROFILE does ("> " / "< " stamps are markers, not passes). Each viewport's span from
## "> Render Viewport i" to "< Render Viewport i" as "viewport i", and the whole frame as "total". Pure.
static func gpu_passes(names: PackedStringArray, times_ns: PackedInt64Array) -> Dictionary:
	var out: Dictionary = {}
	var n: int = mini(names.size(), times_ns.size())
	if n < 2:
		return out
	var opened: Dictionary = {}
	for i: int in n:
		var stamp: String = names[i]
		if stamp.begins_with("> Render Viewport "):
			opened[stamp.trim_prefix("> Render Viewport ")] = times_ns[i]
		elif stamp.begins_with("< Render Viewport "):
			var vp: String = stamp.trim_prefix("< Render Viewport ")
			if opened.has(vp):
				var key: String = "viewport " + vp
				out[key] = float(out.get(key, 0.0)) + float(times_ns[i] - int(opened[vp])) / 1_000_000.0
		if i + 1 < n and not stamp.begins_with(">") and not stamp.begins_with("<"):
			out[stamp] = float(out.get(stamp, 0.0)) + float(times_ns[i + 1] - times_ns[i]) / 1_000_000.0
	out["total"] = float(times_ns[n - 1] - times_ns[0]) / 1_000_000.0
	return out


## Reads the renderer's captured timestamps once per new frame (only there with --gpu-profile).
func _gpu_collect() -> void:
	var rd: RenderingDevice = RenderingServer.get_rendering_device()
	if rd == null:
		return
	var n: int = rd.get_captured_timestamps_count()
	if n < 2:
		return
	var frame: int = rd.get_captured_timestamps_frame()
	if frame == _gpu_last_frame:
		return
	if _gpu_last_frame < 0:
		# The engine eats its own options: --gpu-profile is not in get_cmdline_args, the timestamps say it.
		print("[CPerf] !! --gpu-profile — the renderer captures its pass timestamps ([CPerfG]); the engine"
			+ " also prints its own GPU PROFILE block every second.")
	_gpu_last_frame = frame
	var names := PackedStringArray()
	var times := PackedInt64Array()
	for i: int in n:
		names.append(rd.get_captured_timestamp_name(i))
		times.append(rd.get_captured_timestamp_gpu_time(i))
	var passes: Dictionary = gpu_passes(names, times)
	for k: String in passes:
		_gpu_sum[k] = float(_gpu_sum.get(k, 0.0)) + float(passes[k])
	_gpu_frames += 1


## GPU per pass and per viewport, mean ms a frame over the window ([CPerfG]).
func _print_gpu() -> void:
	if _gpu_frames == 0:
		return
	var mean: Dictionary = {}
	var viewports: Dictionary = {}
	for k: String in _gpu_sum:
		var v: float = float(_gpu_sum[k]) / float(_gpu_frames)
		if k.begins_with("viewport "):
			viewports[k.trim_prefix("viewport ")] = v
		elif k != "total":
			mean[k] = v
	print("[CPerfG] %s gpu total=%.1f ms/frame over %d frames | passes: %s | viewports (%d): %s" % [
		_clock(), float(_gpu_sum.get("total", 0.0)) / float(_gpu_frames), _gpu_frames,
		bands_line(mean, 0.1), viewports.size(), bands_line(viewports, 0.1)])


## The physics burst of the window ([CPerfP]): steps per frame, then ms/s of each part, then the scripts
## by total over the window and by worst frame. `sig+pick` is the physics_frame signal's other subscribers
## and the mouse picking (physics raycasts); `engine` is sync, collision callbacks, flushes, timers,
## navigation and the Jolt steps; `idle` (not physics) the frame cap's sleep, OS events and input.
func _print_physics(window: float) -> void:
	var frames: int = maxi(_frames, 1)
	var w: float = maxf(window, 0.001)
	var total: Dictionary = {}
	for k: String in _pband_sum:
		total[k] = float(_pband_sum[k]) / w
	print(("[CPerfP] %s steps=%d (%.2f/frame) | scripts=%.1f sig+pick=%.1f engine=%.1f idle=%.1f ms/s"
			+ " | by script ms/s: %s | worst frame: %s") % [
		_clock(), _pw_steps, float(_pw_steps) / float(frames),
		float(_pw_scripts_usec) / 1000.0 / w, float(_pw_sig_usec) / 1000.0 / w, float(_pw_engine_usec) / 1000.0 / w,
		float(_pw_idle_usec) / 1000.0 / w,
		bands_line(total, 0.5), bands_line(_pband_max, 1.0)])


## SceneTree::process(), after the multiplayer poll and before the message queue, the transform
## flush and the process group.
func _on_tree_process_frame() -> void:
	_pframe_usec = Time.get_ticks_usec()
	# The probe that splits what follows. `MessageQueue::flush()` is the very next statement
	# (scene_tree.cpp:715) and runs FIFO, so this call sits behind everything already queued: when
	# `_mq_probe` fires that flush is essentially done. A deferred call costs a few BYTES (`msgbuf`
	# peaks at 44 KiB, which is why the queue looked innocent) and can cost a hundred milliseconds to
	# RUN — a CSG rebuild, for one, is a `call_deferred(_update_shape)`.
	_mq_usec = 0
	_mq_probe.call_deferred()


## Runs inside the MessageQueue flush that sits between `process_frame` and the transform flush.
func _mq_probe() -> void:
	_mq_usec = Time.get_ticks_usec()


## Start of RenderingServer::draw(), main thread. Everything between the tail probe and here is the
## message queue flush plus the sync that waits on the render thread.
func _on_frame_pre_draw() -> void:
	_predraw_usec = Time.get_ticks_usec()


## End of RenderingServer::draw(), main thread.
func _on_frame_post_draw() -> void:
	_postdraw_usec = Time.get_ticks_usec()

## Who is parked on `process_frame`, and who on `physics_frame`.
##
## `godot(8).log` (2026-09-09) cornered the 6 fps collapse to `tf=` — `pf<=0`, `tf<=163` — which in
## the 4.7 source (scene/main/scene_tree.cpp:713-719) is exactly three statements:
## `emit_signal("process_frame")`, `MessageQueue::flush()`, `flush_transform_notifications()`, then
## the process group. The message queue is out (`msgbuf` peaks at 44 KiB), so it is the OTHER
## subscribers of that signal or the transform flush — and this line tells them apart, because every
## suspended `await get_tree().process_frame` in the game IS a subscriber and resumes right there,
## where `scripts=` cannot see it. A count of 1 (this autoload alone) points at the flush instead.
func _print_frame_signal_subs() -> void:
	var out: PackedStringArray = []
	for sig_name: StringName in [&"process_frame", &"physics_frame"]:
		# Signal(object, name), not get(): signals are not properties, and `get` would hand back null.
		var conns: Array = Signal(get_tree(), sig_name).get_connections()
		var by: Dictionary = {}
		for c: Dictionary in conns:
			var cb: Callable = c.get("callable", Callable())
			var owner_obj: Object = cb.get_object()
			var who: String = "<freed>"
			if owner_obj != null:
				var sc: Script = owner_obj.get_script() as Script
				who = sc.resource_path.get_file() if sc != null else owner_obj.get_class()
			var key: String = "%s::%s" % [who, str(cb.get_method())]
			by[key] = int(by.get(key, 0)) + 1
		var keys: Array = by.keys()
		keys.sort_custom(func(a: String, b: String) -> bool: return int(by[a]) > int(by[b]))
		var top: PackedStringArray = []
		for k: String in keys.slice(0, 8):
			top.append("%s=%d" % [k, int(by[k])])
		out.append("%s subs=%d%s" % [
			str(sig_name), conns.size(), (" " + " ".join(top)) if not top.is_empty() else ""])
	print("[CPerf&] %s | %s" % [_clock(), " | ".join(out)])


## Give [param node] the band of its script (or of its class, for the engine's own internal process),
## if it processes at the default priority. A viewport keeps its place: it is not ours to order.
func _band_node(node: Node) -> void:
	# Our own probes keep their places (a _process probe sits at physics priority 0, and the other way round).
	if not _bands_on or node == self or node is Viewport or node.get_parent() == self:
		return
	var scr: Script = node.get_script()
	var sname: String = scr.resource_path.get_file() if scr != null else "<no script>"
	if node.process_priority == 0:
		if node.is_processing():
			node.process_priority = _band_priority(sname) + 1
		elif node.is_processing_internal():
			node.process_priority = _band_priority("int:" + node.get_class()) + 1
	if node.process_physics_priority == 0:
		if node.is_physics_processing():
			node.process_physics_priority = _pband_priority(sname) + 1
		elif node.is_physics_processing_internal():
			node.process_physics_priority = _pband_priority("int:" + node.get_class()) + 1


func _on_node_added_band(node: Node) -> void:
	_band_new.append(node)


## The band for a script, created on first sight: a probe at its base priority, its name in the list.
func _band_priority(script_name: String) -> int:
	var k: int = _band_scripts.find(script_name)
	if k < 0:
		k = _band_scripts.size()
		_band_scripts.append(script_name)
		_band_t.append(0)
		_band_probes.append(_band_probe(_BAND_BASE + k * _BAND_STEP, _band_tick.bind(k)))
		# The end probe follows the last band, so the nodes between it and -1 are not that band's.
		_band_end_probe.process_priority = _BAND_BASE + (k + 1) * _BAND_STEP
	return _BAND_BASE + k * _BAND_STEP


## The physics band for a script, created on first sight (see _band_priority).
func _pband_priority(script_name: String) -> int:
	var k: int = _pband_scripts.find(script_name)
	if k < 0:
		k = _pband_scripts.size()
		_pband_scripts.append(script_name)
		_pband_t.append(0)
		_phys_probe(_BAND_BASE + k * _BAND_STEP, func() -> void: _pband_t[k] = Time.get_ticks_usec())
		_pband_end_probe.process_physics_priority = _BAND_BASE + (k + 1) * _BAND_STEP
	return _BAND_BASE + k * _BAND_STEP


func _band_probe(priority: int, tick: Callable) -> Node:
	var probe: _TailProbe = _TailProbe.new()
	probe.name = "CPerfBand%d" % priority
	probe.tick = tick
	probe.process_priority = priority
	add_child(probe)
	probe.set_physics_process(false)
	return probe


func _band_tick(k: int) -> void:
	_band_t[k] = Time.get_ticks_usec()


func _band_rest_tick() -> void:
	_band_rest_usec = Time.get_ticks_usec()


func _band_pos_tick() -> void:
	_band_pos_usec = Time.get_ticks_usec()


## Read the previous frame's band timestamps into per-window maxima. Band k ends where band k+1
## starts; the last band ends at the -1 probe; from there to the +1 probe are the nodes still at
## priority 0 (`rest0`); from the +1 probe to the tail are the scripts with a positive priority.
func _band_collect() -> void:
	var n: int = _band_scripts.size()
	_band_frame.clear()
	for k: int in n:
		var t0: int = _band_t[k]
		var t1: int = _band_t[k + 1] if k + 1 < n else _band_end_usec
		if t0 > 0 and t1 >= t0:
			_band_frame[_band_scripts[k]] = float(t1 - t0) / 1000.0
	# ClientPerf's own _process (the frame's first), then the game's nodes at a negative priority.
	if _prev_frame_start_usec > 0 and _band_self_usec >= _prev_frame_start_usec:
		_band_frame["cperf"] = float(_band_self_usec - _prev_frame_start_usec) / 1000.0
	var first: int = _band_t[0] if n > 0 else _band_end_usec
	var neg: float = 0.0
	if _band_self_usec > 0 and first >= _band_self_usec:
		neg += float(first - _band_self_usec) / 1000.0
	if _band_end_usec > 0 and _band_rest_usec >= _band_end_usec:
		neg += float(_band_rest_usec - _band_end_usec) / 1000.0
	if neg > 0.0:
		_band_frame["prio-"] = neg
	if _band_rest_usec > 0 and _band_pos_usec >= _band_rest_usec:
		_band_frame["rest0"] = float(_band_pos_usec - _band_rest_usec) / 1000.0
	if _band_pos_usec > 0 and _tail_usec >= _band_pos_usec:
		_band_frame["prio+"] = float(_tail_usec - _band_pos_usec) / 1000.0
	for name_k: String in _band_frame:
		_band_max[name_k] = maxf(float(_band_max.get(name_k, 0.0)), float(_band_frame[name_k]))
	# Bands given after reading them: a new probe has no time yet, and starts next frame.
	for node in _band_new:  # untyped: a node freed since would abort a typed loop variable
		if is_instance_valid(node):
			_band_node(node)
	_band_new.clear()


## The bands of the frame just gone, and what [param scripts_ms] holds besides them.
func _bands_of_frame(scripts_ms: float) -> String:
	var banded := 0.0
	for k: String in _band_frame:
		banded += float(_band_frame[k])
	return "%s unbanded=%.1f" % [bands_line(_band_frame, 1.0), scripts_ms - banded]


## [param bands] (name -> ms) from the dearest, those of at least [param min_ms], for a log line.
static func bands_line(bands: Dictionary, min_ms: float) -> String:
	var names: Array = bands.keys().filter(func(k: String) -> bool: return float(bands[k]) >= min_ms)
	names.sort_custom(func(a: String, b: String) -> bool: return float(bands[a]) > float(bands[b]))
	var parts: PackedStringArray = []
	for k: String in names:
		parts.append("%s=%.1f" % [k, float(bands[k])])
	return " ".join(parts)


## Worst frame of the window, per script. Sorted, so the culprit is the first word on the line.
func _print_bands() -> void:
	if not _bands_on or _band_max.is_empty():
		return
	var keys: Array = _band_max.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return float(_band_max[a]) > float(_band_max[b]))
	var parts: PackedStringArray = []
	for k: String in keys.slice(0, 12):
		parts.append("%s=%.1f" % [k, float(_band_max[k])])
	print("[CPerf%%] %s _process worst ms by script: %s" % [_clock(), " ".join(parts)])
