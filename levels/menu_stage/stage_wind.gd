class_name StageWind
extends Node
## The wind of the menu stage: a steady blow the stage dictates (no Horizon behind the menu, so no
## weather systems), breathed by the model's own gusts on the wall clock (the stage freezes the shared
## clock to set its hour), and shown by the very presenters the game uses — the blown dust in the sky
## (WeatherSky, through the planet's weather override), the sand streaks, veils and wisps (StormDust
## around the rig's camera) and the weather loops (WeatherAudio). Nothing is simulated twice: the stage
## only says what the wind is, Planet.weather_override carries it to everyone.

## The blow: speed at 10 m (m/s), where it comes from (compass degrees, 0 = north, 90 = east), the dust
## it carries (optical depth: 0 clear, 0.3 a hazy day), and whether the gusts breathe.
@export var wind_speed_ms: float = 11.0
## Where the wind comes from, compass degrees (0 = north, 90 = east).
@export var wind_from_deg: float = 60.0
## The dust the blow carries, as an optical depth (0 clear, 0.3 a hazy day, 2 a storm).
@export_range(0.0, 3.0, 0.01) var dust_tau: float = 0.25
## Gusts on the wall clock, from the model's hashed sinusoids; off = a perfectly steady wind.
@export var gusts: bool = true
## The ground the sand is taken from (a SurfaceDust family): the outpost stands on corundum dirt.
@export var ground_family: StringName = &"dirt"

## How often the override and the loops are refreshed (s).
const REFRESH_S: float = 0.5
const DUST: SurfaceDust = preload("res://scenes/common/ground_dust.tres")

var _planet: Planet = null
var _rig: Node3D = null
var _dust: StormDust = null
var _audio: WeatherAudio = null
var _age: float = INF


func _init(planet: Planet, rig: Node3D) -> void:
	_planet = planet
	_rig = rig


func _ready() -> void:
	if not is_instance_valid(_planet) or not is_instance_valid(_rig):
		return
	_dust = StormDust.new(_rig, DUST)
	_audio = WeatherAudio.new()
	_audio.name = "StageWeatherAudio"
	_rig.add_child(_audio)
	_apply()


func _exit_tree() -> void:
	if _dust != null:
		_dust.release()
	if is_instance_valid(_planet):
		_planet.weather_override = {}


func _process(delta: float) -> void:
	if not is_instance_valid(_planet) or not is_instance_valid(_rig):
		return
	_age += delta
	if _age >= REFRESH_S:
		_age = 0.0
		_apply()
	if _dust != null:
		_dust.update(delta, ground_family)


## The wind (east, north) in m/s of a blow of [param speed_ms] coming FROM compass bearing
## [param from_deg] (0 = north, 90 = east): it blows toward the opposite bearing.
static func wind_parts(speed_ms: float, from_deg: float) -> Vector2:
	var toward: float = deg_to_rad(from_deg + 180.0)
	return Vector2(speed_ms * sin(toward), speed_ms * cos(toward))


## Write the stage's wind into the planet's override and feed the loops.
func _apply() -> void:
	var parts: Vector2 = wind_parts(wind_speed_ms, wind_from_deg)
	var override: Dictionary = {"wind_east_m_s": parts.x, "wind_north_m_s": parts.y, "dust_tau": dust_tau}
	if gusts:
		var ll: Vector2 = _planet.lonlat_of(_rig.global_position)
		var profile: ClimateProfile = _planet.climate_profile()
		override["gust_factor"] = WeatherLocal.gust_factor(profile.weather_seed if profile != null else 0,
				ll.x, ll.y, Time.get_ticks_msec() * 0.001)
	else:
		override["gust_factor"] = 1.0
	_planet.weather_override = override
	if _audio != null:
		_audio.update(_planet.weather_local_at(_rig.global_position), false)
