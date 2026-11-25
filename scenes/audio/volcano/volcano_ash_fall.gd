extends Node
## CLIENT: ash and lapilli falling around the listener while an erupting plume hangs overhead. The ash
## density above (VolcanoPlume.ash_over, read twice a second) is smoothed over ash_smooth_s; the sound
## follows it, and an on/off envelope fades it in over ash_fade_in_s and out over ash_fade_out_s (an
## S-curve, never an abrupt start or stop). Every ash_switch_s it crossfades to another loop so a long
## fall never repeats itself. Not positional: the ash falls all around.
##
## No class_name: VolcanoSound preloads it by path.

const SoundSet := preload("res://scenes/audio/volcano/volcano_sound_set.gd")
const QUIET_DB := -70.0
## Under this smoothed level (0..1) no ash is falling: the envelope fades out.
const ON_LEVEL := 0.02

var sounds: SoundSet
var bus: StringName = &"SFX"
## Smoothed ash level (0..1), also read by the falling flakes.
var level := 0.0
var _players: Array[AudioStreamPlayer] = []
var _current := 0
var _take := 0
var _target := 0.0
var _envelope := 0.0
var _since_switch := 0.0
var _fade_in := 1.0


## Share (0..1) of the full ash fall for [param ash] over the listener (ash_full = 1). Pure.
static func ash_level(ash: float, ash_full: float) -> float:
	return clampf(ash / maxf(ash_full, 0.001), 0.0, 1.0)


## [param current] moved toward [param target] by a first-order lag of time constant [param tau_s]:
## smooth whatever the frame rate. Pure.
static func smooth_toward(current: float, target: float, delta: float, tau_s: float) -> float:
	return lerpf(current, target, 1.0 - exp(-delta / maxf(tau_s, 0.001)))


## The on/off envelope (0..1) one frame on: up to 1 over [param fade_in_s] while [param on], down to 0 over
## [param fade_out_s] otherwise. Pure.
static func step_envelope(envelope: float, on: bool, delta: float, fade_in_s: float, fade_out_s: float) -> float:
	if on:
		return minf(envelope + delta / maxf(fade_in_s, 0.001), 1.0)
	return maxf(envelope - delta / maxf(fade_out_s, 0.001), 0.0)


## Gain (0..1) of an envelope: an S-curve, so the fade starts and ends without a corner. Pure.
static func envelope_gain(envelope: float) -> float:
	return smoothstep(0.0, 1.0, envelope)


func _ready() -> void:
	for k in 2:
		var player := AudioStreamPlayer.new()
		player.bus = bus
		player.volume_db = QUIET_DB
		add_child(player)
		_players.append(player)


## The target level (0..1), from the plume's ash overhead; 0 = none.
func set_target(target: float) -> void:
	_target = clampf(target, 0.0, 1.0)


func _process(delta: float) -> void:
	if sounds == null:
		return
	level = smooth_toward(level, _target, delta, sounds.ash_smooth_s)
	_envelope = step_envelope(_envelope, level > ON_LEVEL, delta, sounds.ash_fade_in_s, sounds.ash_fade_out_s)
	if _envelope <= 0.0 or sounds.ash_loops.is_empty():
		for player in _players:
			if player.playing:
				player.stop()
		return
	var cur := _players[_current]
	if not cur.playing:
		_start(cur)
		_fade_in = 1.0
	_since_switch += delta
	if _since_switch >= sounds.ash_switch_s and sounds.ash_loops.size() > 1:
		_since_switch = 0.0
		_current = 1 - _current
		_start(_players[_current])
		_fade_in = 0.0
	_fade_in = minf(_fade_in + delta / maxf(sounds.ash_crossfade_s, 0.01), 1.0)
	# The density sets the level, the envelope fades it in and out.
	var base: float = sounds.ash_db + linear_to_db(maxf(level * envelope_gain(_envelope), 0.0001))
	# Equal power between the outgoing loop and the incoming one.
	_players[_current].volume_db = base + linear_to_db(maxf(sin(_fade_in * PI * 0.5), 0.0001))
	var other := _players[1 - _current]
	if other.playing:
		var out: float = cos(_fade_in * PI * 0.5)
		if out <= 0.001:
			other.stop()
		else:
			other.volume_db = base + linear_to_db(out)


func _start(player: AudioStreamPlayer) -> void:
	_take = (_take + 1 + randi() % maxi(sounds.ash_loops.size() - 1, 1)) % sounds.ash_loops.size()
	player.stream = Sfx3D.as_looping(sounds.ash_loops[_take])
	player.volume_db = QUIET_DB
	player.play(randf() * player.stream.get_length())
