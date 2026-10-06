class_name WeatherAudio
extends AudioStreamPlayer
## The weather as the listener hears it: loops of wind, grains and storm rumble, each a
## WeatherAudioLayer heard in its own window of a weather parameter, mixed on one
## AudioStreamSynchronized so they stay in phase and fade into one another — the blend container of
## the middleware the community does not want, in forty lines of GDScript. Non-positional: the air is
## all around the listener. On the SFX bus, so the Audio settings slider holds it like every sound.
##
## Fed by WeatherSampler through Planet.weather_at (update), the same numbers the dust and the sky
## read; the gains ramp toward their targets over SMOOTH_S so a reading every half second never
## steps. Inside a vehicle the whole mix drops by [member inside_db]: the cab muffles the storm.
##
## The parameters a layer can follow (WeatherAudioLayer.parameter): &"wind_speed_m_s", &"dust_tau",
## and &"storm" — 0..1, the larger of the wind over WIND_FULL_MS and the dust over TAU_FULL, so one
## loop can carry both a gale and a dust storm until the sound library has one for each.

const WIND_FULL_MS: float = 25.0
const TAU_FULL: float = 2.0
## The air the loops are written for (kg/m³): thinner air carries less (the noise of a wind is a dynamic
## pressure, ½ρv², so the gain goes as the square root of the density), none carries nothing — the
## wind of the ground is not heard from orbit, nor on a body without air.
const REFERENCE_AIR_KG_M3: float = 1.0
## Seconds a gain takes to ramp to a new target (the weather is read every half second).
const SMOOTH_S: float = 0.6
## Silence, in dB, for a layer out of its window.
const SILENT_DB: float = -80.0

## The loops and their windows. Empty = the one loop the library has today (default_layers).
@export var layers: Array[WeatherAudioLayer] = []
## What the cab of a vehicle takes off the mix, in dB.
@export_range(-40.0, 0.0, 0.5) var inside_db: float = -12.0

var _targets: PackedFloat32Array = PackedFloat32Array()
var _gains: PackedFloat32Array = PackedFloat32Array()
var _inside: bool = false
var _sync: AudioStreamSynchronized = null


## The library's one weather loop so far: a sandstorm (CC0, assets/_universe/audio/ambience), heard
## from a tenth of a storm up, fading in over the next third.
static func default_layers() -> Array[WeatherAudioLayer]:
	var storm := WeatherAudioLayer.new()
	storm.stream = load("res://assets/_universe/audio/ambience/sandstorm_001.ogg")
	storm.parameter = &"storm"
	storm.from = 0.1
	storm.to = 1.0
	storm.fade_in = 0.35
	storm.fade_out = 0.0
	storm.volume_db = -3.0
	return [storm]


func _ready() -> void:
	bus = Sfx3D.SFX_BUS
	if Sfx3D.muted():
		return
	if layers.is_empty():
		layers = default_layers()
	_sync = AudioStreamSynchronized.new()
	_sync.stream_count = layers.size()
	_targets.resize(layers.size())
	_gains.resize(layers.size())
	for i in layers.size():
		var layer: WeatherAudioLayer = layers[i]
		if layer != null and layer.stream != null:
			_sync.set_sync_stream(i, Sfx3D.as_looping(layer.stream))
		_sync.set_sync_stream_volume(i, SILENT_DB)
	stream = _sync
	play()


## The weather at the listener (a WeatherSampler sample, {} for none) and whether they sit in a
## vehicle. Sets the targets; _process ramps the gains.
func update(sample: Dictionary, inside: bool) -> void:
	_inside = inside
	var air: float = air_factor(sample)
	for i in layers.size():
		var layer: WeatherAudioLayer = layers[i]
		_targets[i] = 0.0 if layer == null else air * gain_for(parameter_of(sample, layer.parameter), layer.from,
				layer.to, layer.fade_in, layer.fade_out)


func _process(delta: float) -> void:
	if _sync == null:
		return
	var step: float = clampf(delta / SMOOTH_S, 0.0, 1.0)
	for i in layers.size():
		var gain: float = lerpf(_gains[i], _targets[i], step)
		if absf(gain - _gains[i]) < 1e-4 and gain == _targets[i]:
			continue
		_gains[i] = gain
		var db: float = SILENT_DB if gain <= 1e-4 else linear_to_db(gain) + layers[i].volume_db
		if _inside:
			db += inside_db
		_sync.set_sync_stream_volume(i, maxf(db, SILENT_DB))


## How much of the loops the air here carries, 0..1: the square root of the density over
## REFERENCE_AIR_KG_M3, capped at 1. 0 for an empty sample (no weather: no air known).
static func air_factor(sample: Dictionary) -> float:
	if sample.is_empty():
		return 0.0
	var density: float = float(sample.get("air_density_kg_m3", 0.0))
	return sqrt(clampf(density / REFERENCE_AIR_KG_M3, 0.0, 1.0))


## The value of [param parameter] in a sample: the wind, the dust, or the storm index (0..1, the
## larger of the two against a full storm). 0 for an empty sample or an unknown name.
static func parameter_of(sample: Dictionary, parameter: StringName) -> float:
	if sample.is_empty():
		return 0.0
	match parameter:
		&"wind_speed_m_s":
			return float(sample.get("wind_speed_m_s", 0.0))
		&"dust_tau":
			return float(sample.get("dust_tau", 0.0))
		&"storm":
			return storm_index(sample)
	return 0.0


## 0..1: how much of a full storm this is — the wind over WIND_FULL_MS or the dust over TAU_FULL,
## whichever is the larger.
static func storm_index(sample: Dictionary) -> float:
	var wind: float = float(sample.get("wind_speed_m_s", 0.0)) / WIND_FULL_MS
	var dust: float = float(sample.get("dust_tau", 0.0)) / TAU_FULL
	return clampf(maxf(wind, dust), 0.0, 1.0)


## A layer's gain (0..1) for a parameter [param value]: 0 outside [param from]..[param to], 1 on the
## plateau, a straight ramp over the first [param fade_in] of the window and the last
## [param fade_out] (both shares of the window, 0 = a hard edge).
static func gain_for(value: float, from: float, to: float, fade_in: float, fade_out: float) -> float:
	if to <= from or value < from or value > to:
		return 0.0
	var span: float = to - from
	var gain: float = 1.0
	var rise: float = span * clampf(fade_in, 0.0, 1.0)
	if rise > 0.0:
		gain = minf(gain, (value - from) / rise)
	var fall: float = span * clampf(fade_out, 0.0, 1.0)
	if fall > 0.0:
		gain = minf(gain, (to - value) / fall)
	return clampf(gain, 0.0, 1.0)
