class_name VillageSiren
extends Node3D
## The loudspeaker on a village's mast (CLIENT only): plays the storm siren as the village's replicated alarm
## says (VillageAlarm: WARNING once a minute, DURING in a loop, OFF silent). It decides nothing: the server
## does, and a client joining late hears the current state, in step with the others (siren_position).
##
## poi_villages.gd makes it on a client the first time the alarm is not OFF, MAST_HEIGHT_M over the village's
## centre (the village stands with +Y along the radial), and hands it every change (show_alarm).

## The sound: the same before and during, for a wall and for a storm (mono, 8 s).
const STREAM_PATH := "res://assets/_universe/audio/sfx/environment/weather/village-storm-siren.ogg"
## Height of the loudspeaker over the village's centre, metres: a mast over the roofs.
const MAST_HEIGHT_M := 25.0
## Loudness at FALLOFF_M (dB), the distance the 1/d fall-off starts from (m), and the hard cut-off (m): heard
## to the edge of the largest villages (POI radius up to 2.5 km), about 26 dB down there.
const VOLUME_DB := 0.0
const FALLOFF_M := 150.0
const MAX_DISTANCE_M := 3000.0
## A warning's sounding is not started this close to the sample's end (s).
const TAIL_S := 0.5
## The sirens' mixer bus, made on first use under SFX (ensure_bus): the valley's reverberation, so a
## sounding ends in a tail instead of stopping dead (the sample ends mid-wail, to loop seamlessly).
const BUS := &"VillageSiren"
## How long the siren takes to fade out when the alarm stops it mid-sound (s): a wind-down, not a click.
const STOP_FADE_S := 1.2
## Where that fade ends before the stop, dB under VOLUME_DB: deep enough not to be heard stopping, shallow
## enough that the fade, even in dB, is heard over its whole length.
const FADE_FLOOR_DB := -40.0
var _player: AudioStreamPlayer3D = null
var _sound: AudioStream = null
var _state: StringName = VillageAlarm.OFF
var _since: float = 0.0
var _fade: Tween = null


func _ready() -> void:
	position = Vector3(0.0, MAST_HEIGHT_M, 0.0)
	_sound = load(STREAM_PATH) as AudioStream
	_player = AudioStreamPlayer3D.new()
	_player.name = "Speaker"
	Sfx3D.configure(_player, _sound, VOLUME_DB, FALLOFF_M, MAX_DISTANCE_M, Sfx3D.Attenuation.REALISTIC)
	_player.bus = ensure_bus()
	add_child(_player)
	_restart()


## The sirens' bus, made on first use under SFX: a light, wide outdoor reverberation (effect 0), the
## dry siren kept whole. A siren is mid-pitched and tonal: a little damping keeps its tail from ringing.
static func ensure_bus() -> StringName:
	if AudioServer.get_bus_index(BUS) >= 0:
		return BUS
	var idx: int = AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, BUS)
	AudioServer.set_bus_send(idx, Sfx3D.SFX_BUS)
	var reverb := AudioEffectReverb.new()
	reverb.room_size = 0.9
	reverb.damping = 0.55
	reverb.spread = 1.0
	reverb.hipass = 0.15
	reverb.predelay_msec = 80.0
	reverb.predelay_feedback = 0.2
	reverb.dry = 1.0
	reverb.wet = 0.3
	AudioServer.add_bus_effect(idx, reverb)
	return BUS


## The alarm [param state] begun at [param since] (Globals.reference_time()): the siren follows from now.
## Before _ready (the village applies its first data before it enters the tree) it is only kept.
func show_alarm(state: StringName, since: float) -> void:
	if state == _state and is_equal_approx(since, _since):
		return
	_state = state
	_since = since
	if _player != null:
		_restart()


## Silence, the sample the state plays (the looping copy while DURING), and _process only while not OFF.
## Turned OFF mid-sound, the siren fades out over STOP_FADE_S instead of stopping dead.
func _restart() -> void:
	if _fade != null:
		_fade.kill()
		_fade = null
	_player.volume_db = VOLUME_DB
	set_process(_state != VillageAlarm.OFF)
	if _state == VillageAlarm.OFF and _player.playing and is_inside_tree():
		_fade = create_tween()
		_fade.tween_property(_player, "volume_db", VOLUME_DB + FADE_FLOOR_DB, STOP_FADE_S)
		_fade.tween_callback(_player.stop)
		return
	_player.stop()
	_player.stream = Sfx3D.as_looping(_sound) if _state == VillageAlarm.DURING else _sound


func _process(_delta: float) -> void:
	if _player == null or _sound == null or _player.playing:
		return
	var length := _sound.get_length()
	var at := VillageAlarm.siren_position(_state, _since, Globals.reference_time(), length)
	# A warning's sounding is not started in its last instants: a frame landing there would replay a blip.
	if at >= 0.0 and (_state == VillageAlarm.DURING or at < length - TAIL_S):
		_player.play(at)
