class_name WeatherBench
extends Node
## A dev bench for what the weather costs the GPU (client side, Alt+B, Globals dev tool
## "debug_weather_bench"): the player stands still in the wind, the bench takes each of the weather's
## visual effects away in turn, holds every stage SETTLE_S for the picture to settle, then measures the
## GPU time of each frame (the viewport's timestamp query, rgpu in ClientPerf) for MEASURE_S. One line
## per stage in the log, then a table against the first stage: what each effect costs, in ms.
##
## Each stage takes ONE effect away (the others on), so a stage's saving is that effect's own cost;
## "none" takes them all, and the last stage repeats the first to show the drift (a cloud passing,
## the sun moving): a saving under that drift means nothing.
##
## The switches are static so the presenters (WeatherSky, WeatherMasks, StormDust) read them without a
## reference to the bench; all off outside a run, they cost a bool test.

## Seconds each stage waits before measuring (particles die out, the sky's 0.5 s readings catch up),
## and measures.
const SETTLE_S: float = 3.0
const MEASURE_S: float = 5.0
## The dust layer's march steps tried by the "layer_8_steps" stage (the quality gives 8 to 20).
const LOW_STEPS: int = 8
## The stages, in order: [name, the switches it turns on].
const STAGES: Array = [
	["all", []],
	["no_masks", [&"no_masks"]],
	["no_colliders", [&"no_colliders"]],
	["no_particles", [&"no_particles"]],
	["layer_8_steps", [&"low_steps"]],
	["no_layer", [&"no_layer"]],
	["no_storm", [&"no_storm"]],
	["none", [&"no_masks", &"no_colliders", &"no_particles", &"no_layer", &"no_storm"]],
	["all_again", []],
]

## The dust layer near the eye (aerial_perspective.gdshader, dust_*): density 0.
static var no_layer: bool = false
## The buildings' boxes in the dust layer: none sent.
static var no_masks: bool = false
## The particle colliders in the buildings (GPUParticlesCollisionBox3D): hidden.
static var no_colliders: bool = false
## The storm's particles (StormDust): no new puff.
static var no_particles: bool = false
## The far storm volume (StormField): off, the veil's old storm knob takes over.
static var no_storm: bool = false
## The profile's Mie veil (Sandbox's corundum): at zero (WeatherIsolate; the bench leaves it on).
static var no_veil: bool = false

var _renderer: AtmosphereRenderer = null
var _banner: DevBanner = null  # the stage on screen: the run was invisible, and a 2nd Alt+B aborted it
var _stage: int = 0
var _clock: float = 0.0
var _gpu: PackedFloat64Array = []
var _frame: PackedFloat64Array = []
## Per stage: [name, gpu stats, frame stats].
var _results: Array = []


func _init(renderer: AtmosphereRenderer) -> void:
	_renderer = renderer
	name = "WeatherBench"
	_banner = DevBanner.new("WeatherBenchBanner")
	add_child(_banner)


func _ready() -> void:
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	print("[WeatherBench] start: %d stages of %.0f s + %.0f s — stand still, do not touch the mouse. %s" % [
		STAGES.size(), SETTLE_S, MEASURE_S, _context()])
	_enter(0)


func _process(delta: float) -> void:
	_clock += delta
	if _clock < SETTLE_S:
		return
	_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))
	_frame.append(delta * 1000.0)
	if _clock < SETTLE_S + MEASURE_S:
		return
	var gpu: Dictionary = stats(_gpu)
	var frame: Dictionary = stats(_frame)
	_results.append([STAGES[_stage][0], gpu, frame])
	print("[WeatherBench] %d/%d %-13s gpu mean %.2f median %.2f p95 %.2f ms | frame mean %.2f ms (%.0f fps) | %d frames" % [
		_stage + 1, STAGES.size(), STAGES[_stage][0], gpu["mean"], gpu["median"], gpu["p95"],
		frame["mean"], 1000.0 / maxf(frame["mean"], 0.001), gpu["count"]])
	if _stage + 1 < STAGES.size():
		_enter(_stage + 1)
	else:
		_finish()


## Stop a run early: every switch back off, nothing printed past the stages done.
func abort() -> void:
	print("[WeatherBench] aborted at stage %d/%d" % [_stage + 1, STAGES.size()])
	_apply([])
	queue_free()


func _enter(stage: int) -> void:
	_stage = stage
	_clock = 0.0
	_gpu.clear()
	_frame.clear()
	_apply(STAGES[stage][1])
	print("[WeatherBench] %d/%d %s ..." % [stage + 1, STAGES.size(), STAGES[stage][0]])
	_banner.show_text("weather bench %d/%d: %s  (about %d s left; stand still; Alt+B: abort)" % [
		stage + 1, STAGES.size(), STAGES[stage][0], roundi((STAGES.size() - stage) * (SETTLE_S + MEASURE_S))])


func _finish() -> void:
	_apply([])
	print("[WeatherBench] ── result (GPU ms per frame, median; saving = what the effect costs) ──")
	for line: String in table(_results):
		print("[WeatherBench] %s" % line)
	print("[WeatherBench] done. %s" % _context())
	# The banner outlives the bench a little: the run's end on screen, the numbers in the log.
	_banner.show_text("weather bench done: the results are in the client log ([WeatherBench])")
	_banner.reparent(get_parent())
	get_tree().create_timer(10.0).timeout.connect(_banner.queue_free)
	queue_free()


func _exit_tree() -> void:
	_apply([])


## Turn on exactly [param switches], every other one off.
func _apply(switches: Array) -> void:
	no_layer = &"no_layer" in switches
	no_masks = &"no_masks" in switches
	_set_colliders(&"no_colliders" in switches)
	no_particles = &"no_particles" in switches
	no_storm = &"no_storm" in switches
	if is_instance_valid(_renderer):
		var steps: int = LOW_STEPS if &"low_steps" in switches else clampi(_renderer.view_steps, 8, 20)
		_renderer.set_dust_param(&"dust_steps", steps)


## The colliders' switch, pushed to the colliders already laid (WeatherMasks reads it for new ones).
func _set_colliders(off: bool) -> void:
	no_colliders = off
	if is_instance_valid(_renderer) and _renderer.weather_masks != null:
		_renderer.weather_masks.show_colliders(not off)


## What the bench ran on: the window, the vsync (a frame rate capped by it hides the GPU's), the
## atmosphere's quality and the layer's steps.
func _context() -> String:
	var steps: int = clampi(_renderer.view_steps, 8, 20) if is_instance_valid(_renderer) else -1
	return "window=%s vsync=%d max_fps=%d gpu='%s' atmo_steps=%d layer_steps=%d" % [
		get_viewport().get_visible_rect().size, DisplayServer.window_get_vsync_mode(), Engine.max_fps,
		RenderingServer.get_video_adapter_name(), _renderer.view_steps if is_instance_valid(_renderer) else -1, steps]


## Mean, median, 95th percentile and count of [param samples] (all 0 when empty).
static func stats(samples: PackedFloat64Array) -> Dictionary:
	if samples.is_empty():
		return {"mean": 0.0, "median": 0.0, "p95": 0.0, "count": 0}
	var sorted: PackedFloat64Array = samples.duplicate()
	sorted.sort()
	var total: float = 0.0
	for s: float in sorted:
		total += s
	var n: int = sorted.size()
	var mid: int = n >> 1
	var median: float = sorted[mid] if n % 2 == 1 else (sorted[mid - 1] + sorted[mid]) * 0.5
	return {"mean": total / n, "median": median, "p95": sorted[mini(n - 1, int(ceil(n * 0.95)) - 1)], "count": n}


## The result as lines: each stage's median GPU time and its saving against the first stage.
static func table(results: Array) -> PackedStringArray:
	var lines: PackedStringArray = []
	if results.is_empty():
		return lines
	var base: float = float((results[0][1] as Dictionary)["median"])
	for r: Array in results:
		var median: float = float((r[1] as Dictionary)["median"])
		lines.append("%-13s %6.2f ms   saving %+6.2f ms" % [r[0], median, base - median])
	return lines
