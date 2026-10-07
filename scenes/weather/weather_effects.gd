class_name WeatherEffects
extends Node
## Everything the weather shows and sounds like, in one scene to tune live
## (res://scenes/weather/weather_effects.tscn): its "Audio" child (WeatherAudio, the loops and their
## windows) and its "Dust" child (WeatherDust, the four dust populations and the grains' look). The
## client puts one under its player (and the menu stage under its rig); the presenters read both
## children every refresh, so a change in the remote Inspector while the game runs shows at once.

const SCENE: String = "res://scenes/weather/weather_effects.tscn"


## The effects from their scene; a bare set (code defaults) when the scene cannot be loaded.
static func make() -> WeatherEffects:
	var scene: PackedScene = load(SCENE) as PackedScene
	var fx: WeatherEffects = scene.instantiate() as WeatherEffects if scene != null else null
	if fx == null:
		fx = WeatherEffects.new()
		var audio := WeatherAudio.new()
		audio.name = "Audio"
		fx.add_child(audio)
		var dust := WeatherDust.new()
		dust.name = "Dust"
		fx.add_child(dust)
	return fx


func audio() -> WeatherAudio:
	return get_node_or_null("Audio") as WeatherAudio


func dust() -> WeatherDust:
	return get_node_or_null("Dust") as WeatherDust
