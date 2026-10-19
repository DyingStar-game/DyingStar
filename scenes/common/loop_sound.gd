class_name LoopSound
extends Resource
## The settings of one looping sound (AmbientLoop3D.sound), as data: what it plays and how loud and
## far it carries. Saved as a .tres, one file is shared by every loop that must sound alike -- the
## vehicle lift's alarm at both landings -- and a machine can show its loops in ITS inspector by
## referencing the same files: the lift's winch, rolling and alarm sit in sub-scenes, one of them only
## spawned at run time. The knobs mean what they mean in Sfx3D.configure.

## The sound to loop. Ogg Vorbis: an MP3 starts with the encoder's silence, a tick on every turn.
@export var stream: AudioStream
## Loudness at the falloff distance, in dB.
@export_range(-60.0, 12.0, 0.5) var volume_db: float = -6.0
## Distance (m) at which the sound has its nominal loudness; it fades beyond.
@export_range(0.1, 50.0, 0.1) var falloff: float = 2.0
## Hard cut-off (m): not heard at all beyond it.
@export_range(1.0, 200.0, 1.0) var distance: float = 25.0
## How the sound fades with distance (see Sfx3D.Attenuation).
@export var attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.REALISTIC
