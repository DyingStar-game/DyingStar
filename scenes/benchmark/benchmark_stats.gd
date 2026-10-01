class_name BenchmarkStats
extends RefCounted
## One measuring window of the benchmark: every frame's length plus the engine's own timings, boiled
## down to the numbers the report prints. Pure: the runner reads the engine and hands the values in.

## The graphics card's time fills at least this share of the frame: the card holds the frame back.
const BOUND_SHARE : float = 0.85
## Below this share, it is something else: the game's own work, or a limiter outside the game (AMD
## Chill, a driver frame cap). The engine's process / physics monitors cannot tell which — they count
## the wait for the GPU too (measured: TIME_PROCESS reads the whole frame) — so the report does not
## pretend to: the render_scale step says how much the pixels cost.
const IDLE_SHARE : float = 0.6

var _frames_ms : PackedFloat32Array = PackedFloat32Array()
var _gpu_ms : PackedFloat32Array = PackedFloat32Array()
var _sums : Dictionary = {"cpu": 0.0, "setup": 0.0, "proc": 0.0, "phys": 0.0}
var _counters : Dictionary = {}


## One frame: its length (wall clock, ms) and what the engine says it spent on it, in ms —
## gpu (the root viewport), cpu (render CPU of that viewport), setup (render setup), proc (_process
## of every script), phys (one physics step).
func add_frame(frame_ms: float, sample: Dictionary) -> void:
	_frames_ms.append(frame_ms)
	_gpu_ms.append(float(sample.get("gpu", 0.0)))
	for key in _sums:
		_sums[key] += float(sample.get(key, 0.0))


## What is counted once per window rather than per frame (draw calls, memory, pipelines compiled
## during the window, how the warm-up went). Copied as-is into summary().
func finish(counters: Dictionary) -> void:
	_counters = counters.duplicate()


func frame_count() -> int:
	return _frames_ms.size()


## The window, in numbers. All times in ms; fps from the mean frame; low1 = the frame rate of the
## slowest 1 % of frames (at least one), the figure that tracks stutter better than the mean.
func summary() -> Dictionary:
	var n : int = _frames_ms.size()
	var out : Dictionary = {"frames": n}
	if n == 0:
		for key in ["fps", "mean", "p50", "p95", "p99", "low1", "max", "gpu", "gpu_p95", "cpu", "setup", "proc", "phys"]:
			out[key] = 0.0
		out["hitches"] = 0
		out.merge(_counters)
		return out
	var ordered : PackedFloat32Array = _frames_ms.duplicate()
	ordered.sort()
	var total : float = 0.0
	var hitches : int = 0
	for ms in ordered:
		total += ms
		if ms > PerfMath.HITCH_MS:
			hitches += 1
	var mean : float = total / float(n)
	var slow_count : int = maxi(1, n / 100)
	var slow_total : float = 0.0
	for i in slow_count:
		slow_total += ordered[n - 1 - i]
	var gpu_ordered : PackedFloat32Array = _gpu_ms.duplicate()
	gpu_ordered.sort()
	var gpu_total : float = 0.0
	for ms in gpu_ordered:
		gpu_total += ms
	out["fps"] = 1000.0 / maxf(mean, 0.001)
	out["mean"] = mean
	out["p50"] = PerfMath.percentile(ordered, 0.50)
	out["p95"] = PerfMath.percentile(ordered, 0.95)
	out["p99"] = PerfMath.percentile(ordered, 0.99)
	out["low1"] = 1000.0 / maxf(slow_total / float(slow_count), 0.001)
	out["max"] = ordered[n - 1]
	out["hitches"] = hitches
	out["gpu"] = gpu_total / float(n)
	out["gpu_p95"] = PerfMath.percentile(gpu_ordered, 0.95)
	for key in _sums:
		out[key] = _sums[key] / float(n)
	out.merge(_counters)
	return out


## How a step differs from the baseline: d_frame / d_gpu in ms (negative = the step saved time) and
## d_pct, the frame's change in percent.
static func delta(base: Dictionary, step: Dictionary) -> Dictionary:
	var base_mean : float = float(base.get("mean", 0.0))
	var d_frame : float = float(step.get("mean", 0.0)) - base_mean
	return {
		"d_frame": d_frame,
		"d_gpu": float(step.get("gpu", 0.0)) - float(base.get("gpu", 0.0)),
		"d_pct": 100.0 * d_frame / base_mean if base_mean > 0.0 else 0.0,
	}


## What held the frames back in this window: "gpu" when the graphics card's time fills the frame,
## "not_gpu" when it is well short of it (the game's own work, or a limiter), "mixed" in between,
## "n/a" when the GPU time is not reported at all.
static func hint(window: Dictionary) -> String:
	var frame : float = float(window.get("mean", 0.0))
	var gpu : float = float(window.get("gpu", 0.0))
	if frame <= 0.0 or gpu <= 0.0:
		return "n/a"
	if gpu >= BOUND_SHARE * frame:
		return "gpu"
	if gpu < IDLE_SHARE * frame:
		return "not_gpu"
	return "mixed"
