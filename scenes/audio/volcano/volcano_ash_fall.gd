extends Node
## CLIENT: ash and lapilli falling around the listener while an erupting plume hangs overhead. One loop
## plays at a level that follows the ash above (VolcanoPlume.ash_over), swelling and dying over ash_fade_s;
## every ash_switch_s it crossfades to another loop so a long fall never repeats itself. Not positional:
## the ash falls all around.
##
## No class_name: VolcanoSound preloads it by path.

const SoundSet := preload("res://scenes/audio/volcano/volcano_sound_set.gd")
const QUIET_DB := -70.0

var sounds: SoundSet
var bus: StringName = &"SFX"
var _players: Array[AudioStreamPlayer] = []
var _current := 0
var _take := 0
var _level := 0.0
var _target := 0.0
var _since_switch := 0.0
var _fade_in := 1.0


## Share (0..1) of the full ash fall for [param ash] over the listener (ash_full = 1). Pure.
static func ash_level(ash: float, ash_full: float) -> float:
	return clampf(ash / maxf(ash_full, 0.001), 0.0, 1.0)


func _ready() -> void:
	for k in 2:
		var player := AudioStreamPlayer.new()
		player.bus = bus
		player.volume_db = QUIET_DB
		add_child(player)
		_players.append(player)


## The target level (0..1), from the plume's ash overhead; 0 = none.
func set_target(level: float) -> void:
	_target = clampf(level, 0.0, 1.0)


func _process(delta: float) -> void:
	if sounds == null or sounds.ash_loops.is_empty():
		return
	_level = move_toward(_level, _target, delta / maxf(sounds.ash_fade_s, 0.01))
	if _level <= 0.0:
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
	var base: float = sounds.ash_db + linear_to_db(maxf(_level, 0.0001))
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
