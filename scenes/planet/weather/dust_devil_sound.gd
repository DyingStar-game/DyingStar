class_name DustDevilSound
extends Node3D
## The sound of one dust devil (WeatherPhenomena): the whirl of grit passing by, heard round its foot.
##
## The takes are "passing close by" recordings (WarpZone, assets/_universe/audio/sfx/environment/weather/
## dust-devil-pass-*.ogg: rising, then fading, ~8 s): two players overlap them, a new take starting every
## OVERLAP of a take's length on the other player, so the swell of one covers the fade of the last and the
## devil roars on without a gap or a loop heard. The takes and their pitch follow from the devil's id: the
## same devil sounds the same for every player, two devils side by side do not.
##
## Its loudness follows the devil's strength (WeatherRelief: the wind, the sun on the ground; none in a basin
## under the dust sea); under STRENGTH_SILENT it is silent and its players stopped. Client only (Sfx3D.muted).

const TAKES: Array[String] = [
	"res://assets/_universe/audio/sfx/environment/weather/dust-devil-pass-1.ogg",
	"res://assets/_universe/audio/sfx/environment/weather/dust-devil-pass-2.ogg",
	"res://assets/_universe/audio/sfx/environment/weather/dust-devil-pass-3.ogg",
]
## Under this strength the devil is not heard.
const STRENGTH_SILENT := 0.05

## Loudness (dB) of a full-strength devil at unit_size metres; a weaker one is quieter by its strength.
@export var volume_db: float = -4.0
## Distance (m) at which the devil is heard at volume_db; farther it fades as 1/d. Larger = louder from afar.
@export var unit_size: float = 30.0
## Distance (m) past which the devil is not heard at all.
@export var max_distance: float = 300.0
## How far a take's pitch strays either way (share of 1: 0.08 = ±8 %), drawn from the devil's id.
@export var pitch_spread: float = 0.08
## When the next take starts, as a share of the current one's length (0.5 = halfway): lower = denser overlap.
@export var overlap: float = 0.5

var _players: Array[AudioStreamPlayer3D] = []
var _streams: Array[AudioStream] = []
var _seed: int = 0
var _take: int = 0
var _next_in: float = 0.0
var _strength: float = 0.0


## For the devil of id [param id].
func setup(id: int) -> void:
	_seed = id
	for path: String in TAKES:
		var stream := load(path) as AudioStream if ResourceLoader.exists(path) else null
		if stream != null:
			_streams.append(stream)
	for k in 2:
		var player := AudioStreamPlayer3D.new()
		Sfx3D.configure(player, null, volume_db, unit_size, max_distance, Sfx3D.Attenuation.REALISTIC)
		add_child(player)
		_players.append(player)


## The devil's strength now (0..1): its loudness.
func set_strength(strength: float) -> void:
	_strength = strength
	var db := level_db(volume_db, strength)
	for player in _players:
		player.volume_db = db
		player.max_db = db


func _process(delta: float) -> void:
	if Sfx3D.muted() or _streams.is_empty() or _players.size() < 2:
		return
	if _strength < STRENGTH_SILENT:
		for player in _players:
			if player.playing:
				player.stop()
		_next_in = 0.0
		return
	_next_in -= delta
	if _next_in > 0.0:
		return
	var player := _players[_take % 2]
	var h := WeatherHash.mix(_seed, _take, 7, 3)
	player.stream = _streams[int(WeatherHash.unit(h) * _streams.size()) % _streams.size()]
	player.pitch_scale = 1.0 + (WeatherHash.unit(WeatherHash.mix(h, 1, 0, 0)) * 2.0 - 1.0) * pitch_spread
	player.play()
	_next_in = player.stream.get_length() / player.pitch_scale * clampf(overlap, 0.1, 1.0)
	_take += 1


## The loudness (dB) of a devil of [param strength] (0..1) whose full-strength loudness is [param full_db].
static func level_db(full_db: float, strength: float) -> float:
	return full_db + linear_to_db(clampf(strength, 1e-3, 1.0))
