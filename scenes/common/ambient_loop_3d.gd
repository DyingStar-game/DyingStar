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

## The sound to loop. It loops whatever its import settings say.
@export var stream: AudioStream
## Loudness at the falloff distance, in dB.
@export_range(-60.0, 12.0, 0.5) var volume_db: float = -6.0
## Distance (m) at which the sound has its nominal loudness; it fades beyond.
@export_range(0.1, 50.0, 0.1) var falloff: float = 2.0
## Hard cut-off (m): not heard at all beyond it.
@export_range(1.0, 200.0, 1.0) var distance: float = 25.0
## How the sound fades with distance (see Sfx3D.Attenuation).
@export var attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.REALISTIC

var _player: AudioStreamPlayer3D


func _ready() -> void:
	if Sfx3D.muted() or stream == null:
		return
	_player = AudioStreamPlayer3D.new()
	Sfx3D.configure(_player, Sfx3D.as_looping(stream), volume_db, falloff, distance, attenuation)
	add_child(_player, false, INTERNAL_MODE_BACK)
	_player.play(randf() * stream.get_length())


## The playing sound, or null where it is muted (editor, server).
func player() -> AudioStreamPlayer3D:
	return _player
