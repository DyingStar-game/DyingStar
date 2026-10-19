class_name AmbientLoop3D
extends Node3D

## A sound that loops on its own for as long as the object stands: a generator's hum, a machine's
## drone. Positional, on the SFX bus, through Sfx3D like every other sound of the game, so its knobs
## mean the same as everywhere else. Silent where Sfx3D says so (editor, dedicated server).
##
## Each copy starts at a random point of the sample: a village full of the same generator would
## otherwise hum in phase, and sound like one big machine.
##
## Use a sample that loops without a gap: Ogg Vorbis, as the project's other loops. An MP3 carries the
## encoder's silence at its start (23 ms in the generator's), heard as a tick on every turn.

## What it loops and how loud and far it carries (LoopSound). A resource, so loops that must sound
## alike share one file (the vehicle lift's sounds/*.tres): tuning that file retunes them all. Empty,
## or one with no stream: silent.
@export var sound: LoopSound
## Starts on its own and never stops (a generator's hum). Off: silent until set_running(true), for a
## machine that only runs now and then (the vehicle lift's winch).
@export var autoplay: bool = true

var _player: AudioStreamPlayer3D


func _ready() -> void:
	if Sfx3D.muted() or sound == null or sound.stream == null:
		return
	_player = AudioStreamPlayer3D.new()
	Sfx3D.configure(_player, Sfx3D.as_looping(sound.stream), sound.volume_db, sound.falloff, sound.distance,
			sound.attenuation)
	add_child(_player, false, INTERNAL_MODE_BACK)
	if autoplay:
		_play()


## Run the loop ([param on]) or stop it. A loop already running goes on where it is: told twice, it
## does not start over.
func set_running(on: bool) -> void:
	if _player == null:
		return  # muted here (editor, server), or nothing to play
	if on and not _player.playing:
		_play()
	elif not on and _player.playing:
		_player.stop()


## The playing sound, or null where it is muted (editor, server).
func player() -> AudioStreamPlayer3D:
	return _player


func _play() -> void:
	_player.play(randf() * _player.stream.get_length())
