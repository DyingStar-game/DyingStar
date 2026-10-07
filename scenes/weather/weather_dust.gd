class_name WeatherDust
extends Node
## The look of the weather's dust, tuned in the weather effects scene
## (res://scenes/weather/weather_effects.tscn, node "Dust") and read live by StormDust: four
## populations (DustPopulation) and the grains' shader look (ground_dust.gdshader's uniforms). Change
## a value in the Inspector — the remote one while the game runs — and it shows within half a second;
## a population's capacity or lifetime lays a fresh emitter.

@export_group("Populations")
## The clouds past the visor: from the storm's dust (τ), born upwind around the eye.
@export var clouds: DustPopulation = null
## The low veils laid along the wind just over the ground, all around: from the wind's lift.
## Off by default (rate 0): the ray-marched dust layer (aerial_perspective.gdshader) carries that body now.
@export var veils: DustPopulation = null
## The saltation streaks hopping along the ground at the wind's speed: from the wind's lift.
@export var streaks: DustPopulation = null
## The wisps the sand smokes off the ground, rising into the wind: from the wind's lift.
@export var wisps: DustPopulation = null

@export_group("Look")
## Overall opacity of a grain at full density (the shader's own, before a population's).
@export_range(0.0, 1.0, 0.01) var opacity: float = 0.32
## Width of a puff's soft edge, as a share of its radius.
@export_range(0.0, 1.0, 0.01) var edge_softness: float = 0.6
## Distance (m) over which a puff fades where it meets the ground or a wall.
@export_range(0.0, 4.0, 0.01) var proximity_fade: float = 0.6


func _init() -> void:
	fill_defaults()


## Give every population left empty the code's defaults: a scene without them still has dust.
func fill_defaults() -> void:
	if clouds == null:
		clouds = DustPopulation.make(40.0, 2.2, 1.0, 0.03, 3.0, 256, 12.0, 8.0, 2.5, 1.0, 0.0, 2, 0.5)
	if veils == null:
		veils = DustPopulation.make(0.0, 9.0, 0.12, 0.12, 3.5, 256, 7.2, 24.0, 1.2, 0.9, 0.0, 1, 1.5)
	if streaks == null:
		streaks = DustPopulation.make(80.0, 0.35, 1.0, 0.08, 0.8, 320, 3.15, 10.0, 0.25, 0.85, 0.35, 1, 0.4)
	if wisps == null:
		wisps = DustPopulation.make(0.0, 1.8, 0.22, 0.12, 3.5, 256, 3.5, 14.0, 0.3, 0.7, 0.9, 1, 0.8)


## The grains' look as ground_dust.gdshader uniforms by name.
func look() -> Dictionary:
	return {
		"opacity": opacity, "edge_softness": edge_softness, "proximity_fade": proximity_fade,
	}
