class_name Sfx3D
extends RefCounted

## Shared 3D sound-effect helper: positional (AudioStreamPlayer3D) fire-and-forget playback with a
## per-sound volume, falloff, cut-off and attenuation curve. Used by Vehicle and Player, so the audio
## knobs mean exactly the same thing everywhere. Callers own the "should I be silent?" decision (a
## game server has no audio) and the exported values; this class only plays.

## How a sound fades with distance.
## REALISTIC: 1/d, the real world (-6 dB per doubling) — brutal up close, then it lingers on.
## VERY_SHORT: 1/d², dies fast — a small local noise (a door click, a footstep) that must not travel.
## FAR_REACHING: fades linearly in decibels — the "video game" curve: gentle, predictable, carries
##   far. Use it for a horn that must be heard across the street.
## FLAT: no fading at all — full volume up to the hard cut-off.
enum Attenuation {REALISTIC, VERY_SHORT, FAR_REACHING, FLAT}

## Looping copies of streams, so a held sound (a horn, an engine) loops whatever its import settings
## say, and the copy is built once. Keyed by the original stream.
static var _looping: Dictionary = {}

## Fire-and-forget: play `stream` at `host` (the node the sound comes from). The player node frees
## itself once the sample is over, so nothing accumulates. No-op without a stream.
static func play(host: Node3D, stream: AudioStream, db: float, falloff: float, distance: float,
		attenuation: Attenuation) -> void:
	if stream == null or host == null or not host.is_inside_tree():
		return
	var player := AudioStreamPlayer3D.new()
	configure(player, stream, db, falloff, distance, attenuation)
	player.finished.connect(player.queue_free)
	host.add_child(player)
	player.play()

## Same as play(), with a playback speed: 1.0 = as recorded, 1.1 = slightly higher/faster. Used to
## give repeated samples (footsteps) a bit of natural variation.
static func play_pitched(host: Node3D, stream: AudioStream, db: float, falloff: float, distance: float,
		attenuation: Attenuation, pitch: float) -> void:
	if stream == null or host == null or not host.is_inside_tree():
		return
	var player := AudioStreamPlayer3D.new()
	configure(player, stream, db, falloff, distance, attenuation)
	player.pitch_scale = maxf(pitch, 0.01)
	player.finished.connect(player.queue_free)
	host.add_child(player)
	player.play()

## Apply a sound's four knobs to a 3D player. unit_size is Godot's reference distance (the sound is at
## its nominal volume there, and fades past it); max_distance is the hard cut-off.
static func configure(player: AudioStreamPlayer3D, stream: AudioStream, db: float, falloff: float,
		distance: float, attenuation: Attenuation) -> void:
	player.stream = stream
	player.volume_db = db
	player.unit_size = falloff
	player.max_distance = distance
	player.attenuation_model = model(attenuation)

## Our designer-facing enum -> Godot's attenuation model.
static func model(attenuation: Attenuation) -> AudioStreamPlayer3D.AttenuationModel:
	match attenuation:
		Attenuation.VERY_SHORT:
			return AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE
		Attenuation.FAR_REACHING:
			return AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC
		Attenuation.FLAT:
			return AudioStreamPlayer3D.ATTENUATION_DISABLED
	return AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE  # REALISTIC: 1/d, the real world

## A looping copy of a sound: a held sound (horn, engine) must keep going whatever the sample's import
## settings say (a one-shot sample would honk once and go silent). The stream is DUPLICATED, so the
## shared resource on disk keeps its own settings and the same file used elsewhere does not start
## looping too. Loop is a per-format property (Ogg/MP3 = "loop", WAV = "loop_mode"), hence the cases.
static func as_looping(stream: AudioStream) -> AudioStream:
	if stream == null:
		return null
	if _looping.has(stream):
		return _looping[stream]
	var copy: AudioStream = stream.duplicate()
	if copy is AudioStreamWAV:
		var wav := copy as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		if wav.loop_end <= 0:  # 0 = "no loop region" — loop the whole sample
			wav.loop_end = int(wav.get_length() * wav.mix_rate)
	elif "loop" in copy:
		copy.set("loop", true)
	_looping[stream] = copy
	return copy
