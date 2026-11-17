class_name WeatherIsolate
extends DevBanner
## A dev tool (Alt+U, Globals dev tool "debug_weather_isolate") to find which weather layer draws an
## artefact: each press takes the next layer away, and says on screen what is off, until the stage
## that takes them all away; the press after that puts everything back and closes the tool. Made for
## the dark band over the horizon seen from altitude, blinking every half second (2026-10-08).
##
## Same switches as the GPU bench (WeatherBench's statics), read by WeatherSky, StormDust and
## WeatherMasks: some are read every half second (WeatherSky.REFRESH_S), so a stage can take that long
## to show. Alt+I (debug_isolate_light) takes the aerial perspective and the sky's lights away on top.

## The stages: [what the screen says, the switches it turns on].
const STAGES: Array = [
	["weather: everything on", []],
	["weather: no storm volume", [&"no_storm"]],
	["weather: no near dust layer", [&"no_layer"]],
	["weather: no corundum veil", [&"no_veil"]],
	["weather: none of them", [&"no_storm", &"no_layer", &"no_veil"]],
]

var _stage: int = 0


func _init() -> void:
	super("WeatherIsolate")


## Go to the next stage; past the last one, everything back on and the tool gone. Returns what is
## shown (empty once closed).
func next() -> String:
	_stage += 1
	if _stage >= STAGES.size():
		apply([])
		queue_free()
		return ""
	apply(STAGES[_stage][1])
	show_text("%s  (%d/%d, Alt+U: next)" % [STAGES[_stage][0], _stage, STAGES.size() - 1])
	return shown()


func _exit_tree() -> void:
	apply([])


## Turn on exactly [param switches], every other one off.
static func apply(switches: Array) -> void:
	WeatherBench.no_storm = &"no_storm" in switches
	WeatherBench.no_layer = &"no_layer" in switches
	WeatherBench.no_veil = &"no_veil" in switches
