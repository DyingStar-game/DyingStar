class_name WeatherListener
extends RefCounted
## The weather as the owner player hears it, client side: the wind's loops (WeatherAudio, from
## weather_audio.tscn) fed the weather at the body twice a second, and muffled by the shelter around
## it (ShelterProbe, four times a second: a cab is a full shelter, on foot six rays from the eye).
## The player only calls sample_shelter from its physics frame and update from its _process.

const SCENE: PackedScene = preload("res://scenes/audio/weather/weather_audio.tscn")
## How often (s) the loops read the weather, and the shelter is probed.
const WEATHER_SAMPLE_S: float = 0.5
const SHELTER_SAMPLE_S: float = 0.25
## Height of the eye over the feet (m): where the shelter rays start.
const EYE_HEIGHT_M: float = 1.6

var _player: Player = null
var _audio: WeatherAudio = null
var _weather_age: float = INF  # INF = read at the first update
var _shelter: Dictionary = ShelterProbe.open()
var _shelter_age: float = INF


func _init(player: Player) -> void:
	_player = player


## From the physics frame (the rays need it): how sheltered the body is, four times a second.
func sample_shelter(delta: float) -> void:
	_shelter_age += delta
	if _shelter_age < SHELTER_SAMPLE_S:
		return
	_shelter_age = 0.0
	if is_instance_valid(_player._seat_node):
		_shelter = ShelterProbe.enclosed()
		return
	var planet: Planet = Planet.of(_player)
	var wind: Vector3 = planet.wind_world_at(_player.global_position) if planet != null else Vector3.ZERO
	var up: Vector3 = _player.up_direction if not _player.up_direction.is_zero_approx() else _player.global_basis.y
	_shelter = ShelterProbe.probe(_player, _player.global_position + up * EYE_HEIGHT_M, up, wind,
			Globals.MASK_OBSTACLE)


## From _process: the loops fed the weather at the body twice a second. Built once, under the body, so
## it frees with it.
func update(delta: float) -> void:
	if _audio == null:
		_audio = SCENE.instantiate() as WeatherAudio
		_player.add_child(_audio)
	_weather_age += delta
	if _weather_age < WEATHER_SAMPLE_S:
		return
	_weather_age = 0.0
	var planet: Planet = Planet.of(_player)
	var sample: Dictionary = planet.weather_at(_player.global_position) if planet != null else {}
	_audio.update(sample, float(_shelter.get("shelter", 0.0)))
