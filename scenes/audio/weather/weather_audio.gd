class_name WeatherAudio
extends AudioStreamPlayer
## The weather as the listener hears it: loops of wind, grains and storm rumble, each a
## WeatherAudioLayer heard in its own window of a weather parameter, mixed on one
## AudioStreamSynchronized so they stay in phase and fade into one another — the blend container of
## the middleware the community does not want, in forty lines of GDScript. Non-positional: the air is
## all around the listener. On the SFX bus, so the Audio settings slider holds it like every sound.
##
## Fed through Planet.weather_at (update), the same numbers the wind's dust reads (WeatherSource);
## the gains ramp toward their targets over SMOOTH_S so a reading every half second never steps.
## A shelter (ShelterProbe: a cab, a room, the lee of a wall) drops the mix by [member sheltered_db]
## and closes a low-pass on the mix's own bus: the storm heard through a wall.
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
## The layers are tuned in res://scenes/audio/weather/weather_audio.tscn; the code's default_layers are
## the fallback for a node without any.
## The mix's own bus, made on first use under the SFX bus (the Audio slider still holds it), with the
## low-pass a shelter closes: from the open air's cut-off (the filter is transparent) to a wall's.
const BUS: StringName = &"WeatherAmbience"
const OPEN_CUTOFF_HZ: float = 20000.0
const SHELTERED_CUTOFF_HZ: float = 600.0

## The loops and their windows. Empty = default_layers (the strong wind).
@export var layers: Array[WeatherAudioLayer] = []
## What a full shelter (a cab, a sealed room) takes off the mix, in dB; a lesser shelter, its share.
@export_range(-40.0, 0.0, 0.5) var sheltered_db: float = -18.0

var _targets: PackedFloat32Array = PackedFloat32Array()
var _gains: PackedFloat32Array = PackedFloat32Array()
var _shelter: float = 0.0
var _shelter_now: float = 0.0
var _lowpass: AudioEffectLowPassFilter = null
var _cutoff_hz: float = -1.0
var _sync: AudioStreamSynchronized = null


## The fallback mix: a strong wind (CC0, Nox_Sound, assets/_universe/audio/ambience): fades in from 1 to
## 7 m/s, then holds the level a 12 m/s wind was liked at (2026-10-10).
static func default_layers() -> Array[WeatherAudioLayer]:
	var wind := WeatherAudioLayer.new()
	wind.stream = load("res://assets/_universe/audio/ambience/wind_strong_001.ogg")
	wind.parameter = &"wind_speed_m_s"
	wind.from = 1.0
	wind.to = 80.0
	wind.fade_in = 0.076
	wind.fade_out = 0.0
	wind.volume_db = -13.0
	return [wind]


func _ready() -> void:
	if Sfx3D.muted():
		return
	_lowpass = _ensure_bus()
	bus = BUS
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


## The weather at the listener (Planet.weather_at, {} for none) and how sheltered they are
## (0 open, 1 walled in: ShelterProbe). Sets the targets; _process ramps the gains.
func update(sample: Dictionary, shelter: float) -> void:
	_shelter = clampf(shelter, 0.0, 1.0)
	var air: float = air_factor(sample)
	for i in layers.size():
		var layer: WeatherAudioLayer = layers[i]
		_targets[i] = 0.0 if layer == null else air * gain_for(parameter_of(sample, layer.parameter), layer.from,
				layer.to, layer.fade_in, layer.fade_out)


func _process(delta: float) -> void:
	if _sync == null:
		return
	var step: float = clampf(delta / SMOOTH_S, 0.0, 1.0)
	_shelter_now = lerpf(_shelter_now, _shelter, step)
	var cutoff: float = cutoff_for(_shelter_now)
	if _lowpass != null and absf(cutoff - _cutoff_hz) > 1.0:
		_cutoff_hz = cutoff
		_lowpass.cutoff_hz = cutoff
	for i in layers.size():
		var gain: float = lerpf(_gains[i], _targets[i], step)
		_gains[i] = gain
		var db: float = SILENT_DB if gain <= 1e-4 else linear_to_db(gain) + layers[i].volume_db
		db += sheltered_db * _shelter_now
		_sync.set_sync_stream_volume(i, maxf(db, SILENT_DB))


## How much of the loops the air here carries, 0..1: the square root of the density over
## REFERENCE_AIR_KG_M3, capped at 1. 0 for an empty sample (no weather: no air known).
static func air_factor(sample: Dictionary) -> float:
	if sample.is_empty():
		return 0.0
	var density: float = float(sample.get("air_density_kg_m3", 0.0))
	return sqrt(clampf(density / REFERENCE_AIR_KG_M3, 0.0, 1.0))


## The low-pass cut-off (Hz) for a shelter of [param shelter] (0..1): from OPEN_CUTOFF_HZ to
## SHELTERED_CUTOFF_HZ in octaves, the way the ear hears a wall close.
static func cutoff_for(shelter: float) -> float:
	return exp(lerpf(log(OPEN_CUTOFF_HZ), log(SHELTERED_CUTOFF_HZ), clampf(shelter, 0.0, 1.0)))


## The mix's bus with its low-pass, made once for the whole game and sent to the SFX bus.
static func _ensure_bus() -> AudioEffectLowPassFilter:
	var idx: int = AudioServer.get_bus_index(BUS)
	if idx < 0:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, BUS)
		AudioServer.set_bus_send(idx, Sfx3D.SFX_BUS)
		var filter := AudioEffectLowPassFilter.new()
		filter.cutoff_hz = OPEN_CUTOFF_HZ
		AudioServer.add_bus_effect(idx, filter)
	return AudioServer.get_bus_effect(idx, 0) as AudioEffectLowPassFilter


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
