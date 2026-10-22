class_name NeonIgnition
extends RefCounted

## How a neon tube comes on: the gas strikes a few times before it holds. Shared by what lights like one
## (NeonSign, CabinLight).

## [lit?, seconds] steps, each stretched or shortened a little at random, then the tube holds.
const STEPS: Array = [[true, 0.05], [false, 0.12], [true, 0.04], [false, 0.25], [true, 0.08], [false, 0.06]]


## Strike on [param host]: [param show] is called with each step's lit state, then with true. Returns the
## tween, to kill if the light is switched again meanwhile.
static func strike(host: Node, show: Callable) -> Tween:
	var tween := host.create_tween()
	for step: Array in STEPS:
		tween.tween_callback(show.bind(step[0]))
		tween.tween_interval(step[1] * randf_range(0.6, 1.4))
	tween.tween_callback(show.bind(true))
	return tween
