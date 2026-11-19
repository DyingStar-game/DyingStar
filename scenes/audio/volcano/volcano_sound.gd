class_name VolcanoSound
extends Node3D
## CLIENT: the sounds of one volcano, heard from as far as 80 km and as late as sound travels.
##
## No network state: like the plume and the stones, everything derives from the shared clock and the
## volcano's own schedule (VolcanoActivityProfile). The listener hears the volcano's PAST -- the schedule
## is read at the heard time, the clock less distance / speed of sound (VolcanoAcoustics.heard_time) --
## so at 40 km the blast comes two minutes after its plume, and the delay shrinks as one walks closer.
##
## The players sit PROXY_M from the camera, toward the vent, with Godot's attenuation off: the engine only
## gives the direction. Level, low-pass and reverberation come from VolcanoAcoustics, on one bus per
## audible volcano (the VOICES nearest ones), sent to SFX so the Audio settings slider holds them.

const Acoustics := preload("res://scenes/audio/volcano/volcano_acoustics.gd")
const SoundSet := preload("res://scenes/audio/volcano/volcano_sound_set.gd")
const SOUNDS_PATH := "res://scenes/audio/volcano/volcano_sounds.tres"
## Volcanoes heard at once, the nearest ones: one mixer bus each.
const VOICES := 3
const BUS_PREFIX := "Volcano"
## Distance (m) from the camera of the players that stand for the volcano.
const PROXY_M := 100.0
## Seconds between two readings of the schedule and of the distance curves.
const UPDATE_S := 0.1
## Seconds between two readings of the air at the listener.
const AIR_S := 0.5
## A blast heard this long (s) after its time is still played; later (a player who arrives in the middle
## of an eruption), it is not.
const BLAST_GRACE_S := 3.0
## Under this level (dB) a loop is stopped.
const QUIET_DB := -70.0
## How far either way (share of the mean gap) a later blast of an eruption moves from its even place.
const REPEAT_JITTER := 0.7
## The mixed sounds of one volcano never go over this (dB): the levels can be pushed without clipping.
const CEILING_DB := -0.5
## The view shakes for a camera lower than this (m) over the ground: a ship flying by feels nothing.
const GROUND_M := 8.0
## Fields of view (degrees): no shake under the first (a view zoomed on a screen), all of it from the second.
const ZOOMED_FOV := 30.0
const WALKING_FOV := 55.0

static var _alive: Array[VolcanoSound] = []
## Time of the last blast played, by volcano key: the terrain rebuilds a volcano's nodes as the listener
## moves, and a new node must not play again the blast the one before just played.
static var _played: Dictionary = {}

var sounds: SoundSet
var _plume: VolcanoPlume
var _planet: Planet
var _proxy := Node3D.new()
var _steam: AudioStreamPlayer3D
var _rumble: AudioStreamPlayer3D
var _cracks: AudioStreamPlayer3D
var _dist: float = INF
var _voice: int = -1
var _elapsed: float = UPDATE_S
var _air_elapsed: float = AIR_S
var _air: float = 0.0
var _last_take: AudioStream = null
var _rumble_now: float = 0.0
var _tremor: float = 0.0
var _kick: float = 0.0
var _shaken: Camera3D = null


## The sounds of [param plume]'s volcano, to add next to it (same parent: the vent). Null where nothing
## is heard (editor, game server) or when the sound set is missing.
static func create(plume: VolcanoPlume) -> VolcanoSound:
	if Sfx3D.muted() or plume == null or not ResourceLoader.exists(SOUNDS_PATH):
		return null
	var set_res := load(SOUNDS_PATH) as SoundSet
	if set_res == null:
		return null
	var node := VolcanoSound.new()
	node.name = "Sound"
	node.sounds = set_res
	node._plume = plume
	return node


## The time of the blast of an eruption [param window] (VolcanoActivityProfile.eruption_window): when the
## stones start, after the smoke has begun to form (VolcanoEvent.emission_envelope). Pure.
static func blast_time(window: Dictionary) -> float:
	var length: float = float(window.get("length_s", 0.0))
	return float(window.get("start_unix", 0.0)) + minf(float(window.get("ramp_up_s", 0.0)), length * 0.35)


## The eruption that matters at the heard time [param heard]: the one under way, else the one whose blast
## comes within [param build_up_s]. {} for none.
static func window_at(profile: VolcanoActivityProfile, heard: float, build_up_s: float, volcano_seed: int,
		key: String, dormant: bool) -> Dictionary:
	if profile == null:
		return {}
	var window: Dictionary = profile.eruption_window(heard, volcano_seed, key, dormant)
	if window.is_empty():
		window = profile.eruption_window(heard + build_up_s, volcano_seed, key, dormant)
	return window


## Level (0..1) of the rumble at [param heard]: rises to [param before] over [param build_up_s] up to the
## blast, reaches 1 over [param rise_s], and falls with the eruption's own ramp down. Pure.
static func rumble_level(window: Dictionary, heard: float, build_up_s: float, before: float, rise_s: float) -> float:
	if window.is_empty():
		return 0.0
	var blast: float = blast_time(window)
	if heard < blast:
		return before * clampf(1.0 - (blast - heard) / maxf(build_up_s, 0.01), 0.0, 1.0)
	var end: float = float(window.start_unix) + float(window.length_s)
	var fall: float = clampf((end - heard) / maxf(float(window.ramp_down_s), 0.01), 0.0, 1.0)
	return lerpf(before, 1.0, clampf((heard - blast) / maxf(rise_s, 0.01), 0.0, 1.0)) * fall


## Level (0..1) of the cracking rock at [param heard]: rises over [param build_up_s] up to the blast, then
## dies over [param fade_s]. Pure.
static func cracks_level(window: Dictionary, heard: float, build_up_s: float, fade_s: float) -> float:
	if window.is_empty():
		return 0.0
	var blast: float = blast_time(window)
	if heard < blast:
		return clampf(1.0 - (blast - heard) / maxf(build_up_s, 0.01), 0.0, 1.0)
	return clampf(1.0 - (heard - blast) / maxf(fade_s, 0.01), 0.0, 1.0)


## The time of the blast [param index] of an eruption: 0 the first one (blast_time), then one every
## [param repeat_s] on average, each moved by its own draw of [param salt] -- the same on every client. Pure.
static func blast_time_of(window: Dictionary, index: int, repeat_s: float, salt: int) -> float:
	var first: float = blast_time(window)
	if index <= 0:
		return first
	var shift: float = (VolcanoRandom.hash01(index + salt, 811) - 0.5) * REPEAT_JITTER
	return first + (float(index) + shift) * repeat_s


## The last blast at or before [param heard]: 0 the first one, n the n-th after it, -1 for none (before the
## first, once the eruption falls, or no eruption). [param repeat_s] 0 = the first one only. Pure.
static func blast_index(window: Dictionary, heard: float, repeat_s: float, salt: int) -> int:
	if window.is_empty():
		return -1
	var first: float = blast_time(window)
	var last: float = float(window.start_unix) + float(window.length_s) - float(window.ramp_down_s)
	if heard < first or heard >= last:
		return -1
	if repeat_s <= 0.0:
		return 0
	var index: int = int((heard - first) / repeat_s) + 1
	while index > 0 and blast_time_of(window, index, repeat_s, salt) > heard:
		index -= 1
	return index


## What the blast [param index] loses (dB, <= 0) against the first one: nothing for the first, then its own
## draw between 2 dB and [param drop_db]. Pure.
static func blast_drop_db(index: int, drop_db: float, salt: int) -> float:
	if index <= 0:
		return 0.0
	return -lerpf(2.0, maxf(drop_db, 2.0), VolcanoRandom.hash01(index + salt, 812))


## The blast to play at [param heard], or -1: each one once ([param last_blast] is the time of the last one
## played, NAN for none), and only as it passes -- not to a listener who arrives [param grace_s] after it. Pure.
static func blast_due(window: Dictionary, heard: float, last_blast: float, grace_s: float, repeat_s: float,
		salt: int) -> int:
	var index: int = blast_index(window, heard, repeat_s, salt)
	if index < 0:
		return -1
	var at: float = blast_time_of(window, index, repeat_s, salt)
	# Not is_equal_approx: its tolerance is relative, hours wide on a clock in seconds since 1970.
	if heard - at >= grace_s or (not is_nan(last_blast) and absf(at - last_blast) < 0.01):
		return -1
	return index


## How much (0..1) of the ground's shake reaches [param distance_m]: all of it up to [param full_m], none
## from [param range_m]. Pure.
static func tremor_share(distance_m: float, full_m: float, range_m: float) -> float:
	return 1.0 - smoothstep(full_m, maxf(range_m, full_m + 1.0), distance_m)


## How much (0..1) of the shake a view of [param fov_deg] degrees takes: none of it zoomed in (the DataPad
## read on the wrist, where a centimetre is the whole screen), all of it at a walking field. Pure.
static func steady_share(fov_deg: float) -> float:
	return smoothstep(ZOOMED_FOV, WALKING_FOV, fov_deg)


## The tremor comes in waves: 0 (the ground is still) .. 1 (a wave at its height) at the time [param t] (s),
## a few seconds of shake then a longer calm, never on a beat. Pure.
static func swell(t: float) -> float:
	var slow: float = sin(t * 0.9) * 0.5 + sin(t * 0.37 + 1.3) * 0.3 + sin(t * 0.143 + 4.0) * 0.2
	return smoothstep(0.1, 0.6, slow)


## A restless value in -1..1 at the time [param t] (s): three hums that never fall in step. Pure.
static func wobble(t: float, phase: float) -> float:
	return sin(t * 31.0 + phase) * 0.5 + sin(t * 47.3 + phase * 1.7) * 0.3 + sin(t * 13.1 + phase * 0.6) * 0.2


## What a stronger eruption adds to its sounds (dB), around the middle strength of the random ones.
static func strength_db(strength: float) -> float:
	return clampf(linear_to_db(maxf(strength, 0.05) / 1.2), -6.0, 6.0)


## The level (dB) of a sound of nominal [param base_db], [param distance_db] taken by the distance, heard
## at the share [param level] (0..1) through air that carries [param air] (0..1) of it. Pure.
static func level_db(base_db: float, distance_db: float, level: float, air: float) -> float:
	var share: float = clampf(level, 0.0, 1.0) * clampf(air, 0.0, 1.0)
	if share <= 0.0001:
		return Acoustics.SILENT_DB
	return maxf(base_db + distance_db + linear_to_db(share), Acoustics.SILENT_DB)


## The mixer bus of the voice [param voice], made on first use under SFX: a low-pass (effect 0) and a
## reverberation (effect 1), then a limiter.
static func ensure_bus(voice: int) -> StringName:
	var bus := StringName("%s%d" % [BUS_PREFIX, voice])
	if AudioServer.get_bus_index(bus) >= 0:
		return bus
	var idx: int = AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, bus)
	AudioServer.set_bus_send(idx, Sfx3D.SFX_BUS)
	var filter := AudioEffectLowPassFilter.new()
	filter.cutoff_hz = Acoustics.OPEN_CUTOFF_HZ
	AudioServer.add_bus_effect(idx, filter)
	# A wide open space: long, dark, late -- the relief answering, not a room.
	var reverb := AudioEffectReverb.new()
	reverb.room_size = 0.95
	reverb.damping = 0.7
	reverb.spread = 1.0
	reverb.predelay_msec = 250.0
	reverb.predelay_feedback = 0.35
	reverb.dry = 1.0
	reverb.wet = 0.0
	AudioServer.add_bus_effect(idx, reverb)
	var limiter := AudioEffectHardLimiter.new()
	limiter.ceiling_db = CEILING_DB
	AudioServer.add_bus_effect(idx, limiter)
	return bus


func _ready() -> void:
	_alive.append(self)
	_planet = SurfaceProbe.planet_of(self)
	_proxy.name = "Proxy"
	add_child(_proxy)
	_steam = _loop(sounds.steam)
	_rumble = _loop(sounds.rumble)
	_cracks = _loop(sounds.cracks)


func _exit_tree() -> void:
	_alive.erase(self)
	_still()


func _process(delta: float) -> void:
	var viewport := get_viewport()
	var cam: Camera3D = viewport.get_camera_3d() if viewport != null else null
	if cam == null or not is_instance_valid(_plume):
		_silence()
		_still()
		return
	var eye: Vector3 = to_local(cam.global_position)
	_dist = eye.length()
	# Every frame: the direction must not lag behind a fast listener.
	_proxy.position = eye * (1.0 - PROXY_M / _dist) if _dist > PROXY_M else Vector3.ZERO
	_shake(cam, delta)
	_elapsed += delta
	_air_elapsed += delta
	if _elapsed < UPDATE_S:
		return
	_elapsed = 0.0
	if _dist >= sounds.explosion_range_m and _dist >= sounds.rumble_range_m:
		_silence()
		return
	var rank: int = 0
	for other: VolcanoSound in _alive:
		if other != self and other._dist < _dist:
			rank += 1
	if rank >= VOICES:
		_silence()
		return
	if _air_elapsed >= AIR_S:
		_air_elapsed = 0.0
		var sample: Dictionary = _planet.weather_at(cam.global_position) if is_instance_valid(_planet) else {}
		_air = WeatherAudio.air_factor(sample)
	_set_voice(rank)
	_hear(cam)


## Reads the schedule at the heard time and sets every sound.
func _hear(cam: Camera3D) -> void:
	var model: VolcanoPlumeModel = _plume.model
	var heard: float = Acoustics.heard_time(VolcanoPlume.clock(), _dist, sounds.sound_speed_m_s)
	var window: Dictionary = window_at(model.profile, heard, sounds.build_up_s, model.volcano_seed,
			model.volcano_key, model.dormant)
	var boost: float = strength_db(float(window.get("strength", 1.2)))
	var idx: int = AudioServer.get_bus_index(ensure_bus(_voice))
	(AudioServer.get_bus_effect(idx, 0) as AudioEffectLowPassFilter).cutoff_hz = Acoustics.cutoff_hz(
			_dist, sounds.muffle_near_m, sounds.muffle_far_m, sounds.muffle_far_hz)
	(AudioServer.get_bus_effect(idx, 1) as AudioEffectReverb).wet = Acoustics.reverb_wet(
			_dist, sounds.muffle_near_m, sounds.muffle_far_m, sounds.reverb_near, sounds.reverb_far)
	_drive(_steam, level_db(sounds.steam_db, Acoustics.gain_db(_dist, sounds.steam_full_m, sounds.steam_range_m,
			sounds.far_db), 0.0 if model.dormant else 1.0, _air))
	_rumble_now = rumble_level(window, heard, sounds.build_up_s, sounds.rumble_before, sounds.rumble_rise_s)
	_drive(_rumble, level_db(sounds.rumble_db + boost, Acoustics.gain_db(_dist, sounds.rumble_full_m,
			sounds.rumble_range_m, sounds.far_db), _rumble_now, _air))
	_tremor = 0.0
	if _voice == 0 and _dist < sounds.tremor_range_m:
		if _plume.height_over_ground(_plume.to_local(cam.global_position)) < GROUND_M:
			_tremor = tremor_share(_dist, sounds.tremor_full_m, sounds.tremor_range_m)
	_drive(_cracks, level_db(sounds.cracks_db + boost, Acoustics.gain_db(_dist, sounds.cracks_full_m,
			sounds.cracks_range_m, sounds.far_db), cracks_level(window, heard, sounds.build_up_s,
			sounds.cracks_fade_s), _air))
	var salt: int = model.volcano_seed ^ int(float(window.get("start_unix", 0.0)))
	var last: float = float(_played.get(model.volcano_key, NAN))
	var index: int = blast_due(window, heard, last, BLAST_GRACE_S, sounds.explosion_repeat_s, salt)
	if index >= 0:
		_played[model.volcano_key] = blast_time_of(window, index, sounds.explosion_repeat_s, salt)
		var drop: float = blast_drop_db(index, sounds.explosion_repeat_drop_db, salt)
		_kick = db_to_linear(drop)
		_blast(level_db(sounds.explosion_db + boost + drop, Acoustics.gain_db(_dist, sounds.explosion_full_m,
				sounds.explosion_range_m, sounds.far_db), 1.0, _air))


## Moves the view with the ground, every frame: the tremor of the eruption and the kick of each blast,
## through the camera's frustum offsets -- its transform, which the player's look drives, is left alone.
func _shake(cam: Camera3D, delta: float) -> void:
	_kick = move_toward(_kick, 0.0, delta / sounds.tremor_kick_s)
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var reach: float = _tremor * (sounds.tremor_m * _rumble_now * swell(t) + sounds.tremor_kick_m * _kick * _kick)
	reach *= steady_share(cam.fov)
	if reach <= 0.0001:
		_still()
		return
	if _shaken != cam:
		_still()
		_shaken = cam
	cam.h_offset = reach * wobble(t, 0.0)
	cam.v_offset = reach * wobble(t, 7.3)


## Gives the view back as it was.
func _still() -> void:
	if is_instance_valid(_shaken):
		_shaken.h_offset = 0.0
		_shaken.v_offset = 0.0
	_shaken = null


## One blast of an eruption: a take that is not the last one, freed when it is over.
func _blast(db: float) -> void:
	var delay: float = Acoustics.delay_s(_dist, sounds.sound_speed_m_s)
	print("[VolcanoSound] explosion %s d=%.1f km delay=%.0f s level=%.0f dB" % [
			_plume.model.volcano_key, _dist / 1000.0, delay, db])
	if db <= QUIET_DB:
		return
	_last_take = SurfaceSounds.pick_from(sounds.explosions, _last_take)
	if _last_take == null:
		return
	var player := AudioStreamPlayer3D.new()
	Sfx3D.configure(player, _last_take, db, 1.0, 0.0, Sfx3D.Attenuation.FLAT)
	player.bus = ensure_bus(_voice)
	player.finished.connect(player.queue_free)
	_proxy.add_child(player)
	player.play()


## A silent looping player on the proxy, started by _drive when it has something to say.
func _loop(stream: AudioStream) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	Sfx3D.configure(player, Sfx3D.as_looping(stream), Acoustics.SILENT_DB, 1.0, 0.0, Sfx3D.Attenuation.FLAT)
	_proxy.add_child(player)
	return player


## Holds [param player] at [param db]: stopped under QUIET_DB, started anywhere in its loop otherwise (two
## volcanoes do not rumble in phase).
func _drive(player: AudioStreamPlayer3D, db: float) -> void:
	if player.stream == null:
		return
	if db <= QUIET_DB:
		if player.playing:
			player.stop()
		return
	player.volume_db = db
	# max_db caps volume_db plus the distance gain: it must follow a level that moves (Sfx3D.configure).
	player.max_db = db
	if not player.playing:
		player.play(randf() * player.stream.get_length())


func _set_voice(voice: int) -> void:
	if voice == _voice:
		return
	_voice = voice
	var bus: StringName = ensure_bus(voice)
	for child: Node in _proxy.get_children():
		if child is AudioStreamPlayer3D:
			(child as AudioStreamPlayer3D).bus = bus


func _silence() -> void:
	_rumble_now = 0.0
	_tremor = 0.0
	for player: AudioStreamPlayer3D in [_steam, _rumble, _cracks]:
		if player != null and player.playing:
			player.stop()
