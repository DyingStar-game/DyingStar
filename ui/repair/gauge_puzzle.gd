class_name GaugePuzzle
extends RefCounted

## The repair's small game (GaugeRepairPanel): COUNT gauges to bring each into its target band with
## COUNT regulators, each regulator also pushing the next gauge -- a move that sets one unsets its
## neighbour a little. It stands for the work, nothing of it is simulated (services ADR 0020).
##
## Pure: everything is in 0..1, a puzzle is drawn from a seed and always has a solution.

## Gauges, and regulators.
const COUNT := 3
## How much of the next regulator a gauge takes, against 1 of its own.
const COUPLING := 0.35
## A gauge is in its band this close to its target.
const TOLERANCE := 0.04
## A puzzle's regulators start and end no closer to the stops than this.
const MARGIN := 0.1


## What the gauges read for the regulators [param sliders] (COUNT values in 0..1).
static func values(sliders: Array) -> Array:
	var out: Array = []
	for i: int in COUNT:
		var own := clampf(float(sliders[i]), 0.0, 1.0)
		var next := clampf(float(sliders[(i + 1) % COUNT]), 0.0, 1.0)
		out.append((own + COUPLING * next) / (1.0 + COUPLING))
	return out


## Whether every gauge of [param read] is in the band of its target of [param targets].
static func aligned(read: Array, targets: Array) -> bool:
	if read.size() != COUNT or targets.size() != COUNT:
		return false
	for i: int in COUNT:
		if absf(float(read[i]) - float(targets[i])) > TOLERANCE:
			return false
	return true


## The puzzle of [param puzzle_seed]: {"targets": what the gauges must read, "start": where the regulators
## stand}. The targets are what some regulators give, so they can be reached; the start is not aligned.
static func make(puzzle_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = puzzle_seed
	var targets: Array = values(_draw(rng))
	var start: Array = _draw(rng)
	# A start that happens to be solved, or nearly: push it to the stops, away from every solution drawn
	# inside the margins.
	while aligned(values(start), targets):
		start = start.map(func(s: float) -> float: return 0.0 if s >= 0.5 else 1.0)
	return {"targets": targets, "start": start}


static func _draw(rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	for i: int in COUNT:
		out.append(rng.randf_range(MARGIN, 1.0 - MARGIN))
	return out
