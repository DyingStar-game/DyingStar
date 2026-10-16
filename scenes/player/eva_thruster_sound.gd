class_name EvaThrusterSound
extends AudioStreamPlayer3D
## The EVA thrusters' hiss, looped while a weightless player pushes (Player.thrusting). Faded in and out
## rather than cut: a valve opens and closes, it does not click. Lives on every avatar of a client, the
## owner's and the others', and is never built on the game server.

## Seconds to reach full loudness once the thrusters fire.
const ATTACK_S := 0.08
## Seconds to fall silent once they stop: a long tail, the pressure in the line bleeding out, so the
## hiss does not end dry.
const RELEASE_S := 0.6
## Playback speed the hiss sags to as it dies (1.0 at full flow): less pressure, a lower, softer sound.
const RELEASE_PITCH := 0.85
## Each burst picks its playback speed within 1.0 +/- this: the same hiss every time sounds like a machine.
const PITCH_JITTER := 0.08

var _db: float = 0.0
var _level: float = 0.0
var _pitch: float = 1.0


## Set the sound up from the player's "EVA thrusters" knobs (see Sfx3D.configure).
func setup(stream: AudioStream, db: float, falloff: float, distance: float,
		attenuation: Sfx3D.Attenuation) -> void:
	Sfx3D.configure(self, Sfx3D.as_looping(stream), db, falloff, distance, attenuation)
	_db = db


## Loudness share (0..1) after [param delta] seconds, from [param level], thrusters [param on] or not.
## Pure, for the tests.
static func next_level(level: float, on: bool, delta: float) -> float:
	if on:
		return move_toward(level, 1.0, delta / ATTACK_S)
	return move_toward(level, 0.0, delta / RELEASE_S)


## Called every frame: follows [param on], playing only while it can be heard.
func update(on: bool, delta: float) -> void:
	_level = next_level(_level, on, delta)
	if _level <= 0.0:
		if playing:
			stop()
		return
	volume_db = _db + linear_to_db(_level)
	if not playing:
		_pitch = randf_range(1.0 - PITCH_JITTER, 1.0 + PITCH_JITTER)  # a new burst, from silence
	# Fading in, the valve opens at full pressure; fading out, the flow (and the pitch) drops with it.
	pitch_scale = _pitch * (1.0 if on else lerpf(RELEASE_PITCH, 1.0, _level))
	if not playing:
		play()
