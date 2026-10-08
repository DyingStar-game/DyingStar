class_name WeatherIsolate
extends CanvasLayer
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
	["weather: no blown sand slab in the sky", [&"no_blow"]],
	["weather: no storm volume", [&"no_storm"]],
	["weather: no near dust layer", [&"no_layer"]],
	["weather: no corundum veil", [&"no_veil"]],
	["weather: none of them", [&"no_blow", &"no_storm", &"no_layer", &"no_veil"]],
]

var _stage: int = 0
var _label: Label = null


func _init() -> void:
	name = "WeatherIsolate"
	layer = 100
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_label.position.y = 90.0
	_label.add_theme_font_size_override(&"font_size", 22)
	_label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_label.add_theme_constant_override(&"outline_size", 6)
	add_child(_label)


## Go to the next stage; past the last one, everything back on and the tool gone. Returns what is
## shown (empty once closed).
func next() -> String:
	_stage += 1
	if _stage >= STAGES.size():
		apply([])
		queue_free()
		return ""
	apply(STAGES[_stage][1])
	_label.text = "%s  (%d/%d, Alt+U: next)" % [STAGES[_stage][0], _stage, STAGES.size() - 1]
	return _label.text


func _exit_tree() -> void:
	apply([])


## Turn on exactly [param switches], every other one off.
static func apply(switches: Array) -> void:
	WeatherBench.no_blow = &"no_blow" in switches
	WeatherBench.no_storm = &"no_storm" in switches
	WeatherBench.no_layer = &"no_layer" in switches
	WeatherBench.no_veil = &"no_veil" in switches
