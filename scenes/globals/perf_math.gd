class_name PerfMath
extends RefCounted
## The few numbers every performance readout computes the same way: shared by ClientPerf's log and
## the in-game benchmark, so the two can never disagree on what "p99" or "a hitch" means.

## A frame longer than this, in milliseconds, is a hitch: a stall the player feels, not a slow frame.
const HITCH_MS : float = 50.0

## The engine's pipeline-compilation counters. A compilation outside a loading screen is a stutter the
## developer never sees on their own machine (the driver caches the pipeline after the first time).
const PIPE_MONITORS : Array[int] = [
	Performance.PIPELINE_COMPILATIONS_CANVAS,
	Performance.PIPELINE_COMPILATIONS_MESH,
	Performance.PIPELINE_COMPILATIONS_SURFACE,
	Performance.PIPELINE_COMPILATIONS_DRAW,
	Performance.PIPELINE_COMPILATIONS_SPECIALIZATION,
]


## Nearest-rank percentile of an ASCENDING series: q = 0.5 is the median, 1.0 the maximum. 0 when empty.
static func percentile(ordered: PackedFloat32Array, q: float) -> float:
	var n : int = ordered.size()
	if n == 0:
		return 0.0
	return ordered[clampi(int(round(q * float(n - 1))), 0, n - 1)]


## Every pipeline compiled since the game started, all kinds together. Only ever grows.
static func pipeline_total() -> int:
	var total : int = 0
	for monitor : int in PIPE_MONITORS:
		total += int(Performance.get_monitor(monitor))
	return total
