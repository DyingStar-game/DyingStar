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
const ImpactSounds := preload("res://scenes/audio/volcano/volcano_impact_sounds.gd")
const AshFall := preload("res://scenes/audio/volcano/volcano_ash_fall.gd")
const AshVisual := preload("res://scenes/audio/volcano/volcano_ash_visual.gd")
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
## Level (dB) of the first echo against the sound itself: closer to 0 = a wider, emptier space.
const ECHO_DB := -9.0
## The view shakes for a camera lower than this (m) over the ground: a ship flying by feels nothing.
const GROUND_M := 8.0
## Fields of view (degrees): no shake under the first (a view zoomed on a screen), all of it from the second.
const ZOOMED_FOV := 30.0
const WALKING_FOV := 55.0

static var _alive: Array[VolcanoSound] = []
## Time of the last blast played, by volcano key: the terrain rebuilds a volcano's nodes as the listener
## moves, and a new node must not play again the blast the one before just played.
static var _played: Dictionary = {}
## The same for the kicks of the ground, which come first.
static var _felt: Dictionary = {}
## The same for the quakes of strong eruptions.
static var _quaked: Dictionary = {}

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
var _ground_level: float = 0.0
var _tremor: float = 0.0
var _kick: float = 0.0
var _shaken: Camera3D = null
var _impacts: ImpactSounds
var _ash: AshFall
var _ash_visual: AshVisual
## Camera height over the ground (m) and local wind (m/s, plume frame), read with the schedule.
var _height: float = INF
var _ash_wind := Vector3.ZERO
## The camera stands on the ground (GROUND_M), read with the schedule: only then is anything felt.
var _grounded: bool = false
## The quake under way: its age and length (s), and the share of it that reaches here (0..1).
var _quake_age: float = INF
var _quake_len: float = 0.0
var _quake_share: float = 0.0
## The shock wave of the last blast: dies from 1 to 0 over shock_s; its strength here (0..1).
var _shock: float = 0.0
var _shock_share: float = 0.0


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


## How much (0..1) of a quake or a shock wave reaches [param distance_m]: all of it up to [param full_m], then
## weakening as a wave spreading over the surface (1 / square root of the distance), and none from
## [param range_m]. Pure.
static func falloff_share(distance_m: float, full_m: float, range_m: float) -> float:
	var spread: float = sqrt(full_m / maxf(distance_m, full_m))
	return spread * (1.0 - smoothstep(full_m, maxf(range_m, full_m + 1.0), distance_m))


## The time of the quake [param index] of an eruption: the first one half a gap after the first blast, then
## one every [param repeat_s] on average, each moved by its own draw of [param salt] -- the same on every
## client. Pure.
static func quake_time_of(window: Dictionary, index: int, repeat_s: float, salt: int) -> float:
	var shift: float = (VolcanoRandom.hash01(maxi(index, 0) + salt, 821) - 0.5) * REPEAT_JITTER
	return blast_time(window) + (0.5 + float(maxi(index, 0)) + shift) * repeat_s


## The last quake at or before [param felt]: 0 the first one, -1 for none -- no eruption, one weaker than
## [param min_strength], before the first quake or once the eruption falls, [param repeat_s] 0. Pure.
static func quake_index(window: Dictionary, felt: float, repeat_s: float, salt: int, min_strength: float) -> int:
	if window.is_empty() or repeat_s <= 0.0 or float(window.get("strength", 0.0)) < min_strength:
		return -1
	var last: float = float(window.start_unix) + float(window.length_s) - float(window.ramp_down_s)
	if felt >= last:
		return -1
	var index: int = maxi(int((felt - blast_time(window)) / repeat_s) + 1, 0)
	while index >= 0 and quake_time_of(window, index, repeat_s, salt) > felt:
		index -= 1
	return index


## The quake to feel at [param felt], or -1: each one once ([param last_quake] is the time of the last one
## felt, NAN for none), and only as it passes -- not by a listener who arrives [param grace_s] after it. Pure.
static func quake_due(window: Dictionary, felt: float, last_quake: float, grace_s: float, repeat_s: float,
		salt: int, min_strength: float) -> int:
	var index: int = quake_index(window, felt, repeat_s, salt, min_strength)
	if index < 0:
		return -1
	var at: float = quake_time_of(window, index, repeat_s, salt)
	if felt - at >= grace_s or (not is_nan(last_quake) and absf(at - last_quake) < 0.01):
		return -1
	return index


## The take of the event [param index] among [param takes], drawn from [param salt] on [param channel]: the
## same on every client. Null for no take. Pure.
static func pick_take(takes: Array, index: int, salt: int, channel: int) -> AudioStream:
	if takes.is_empty():
		return null
	var at: int = mini(int(VolcanoRandom.hash01(index + salt, channel) * takes.size()), takes.size() - 1)
	return takes[at] as AudioStream


## Share (0..1) of a blast heard as the far shock wave rather than the near explosion at [param distance_m]:
## 0 up to [param from_m], 1 from [param to_m]. The two take cos / sin of it (equal power). Pure.
static func wave_share(distance_m: float, from_m: float, to_m: float) -> float:
	return smoothstep(from_m, maxf(to_m, from_m + 1.0), distance_m)


## Length (s) of the quake [param index]: its own draw between [param min_s] and [param max_s]. Pure.
static func quake_length(index: int, salt: int, min_s: float, max_s: float) -> float:
	return lerpf(min_s, maxf(max_s, min_s), VolcanoRandom.hash01(index + salt, 822))


## Strength (0..1) of a quake [param age_s] into its [param length_s]: a sharp onset, then it dies over its
## second half. 0 before and after. Pure.
static func quake_envelope(age_s: float, length_s: float) -> float:
	if age_s < 0.0 or age_s >= length_s:
		return 0.0
	return smoothstep(0.0, minf(0.15, length_s * 0.2), age_s) * (1.0 - smoothstep(length_s * 0.5, length_s, age_s))


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
## reverberation (effect 1), then an echo and a limiter.
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
	# A wide open space, kept dark and without feedback: brighter or fed back, its combs ring like a
	# saucepan on a rumble (heard 2026-11-19). The feeling of space comes from the echo below.
	var reverb := AudioEffectReverb.new()
	reverb.room_size = 0.85
	reverb.damping = 0.95
	reverb.spread = 1.0
	reverb.predelay_msec = 120.0
	reverb.predelay_feedback = 0.0
	reverb.dry = 1.0
	reverb.wet = 0.0
	AudioServer.add_bus_effect(idx, reverb)
	# The slopes answering: two late, duller repeats, one on each side, and their own fading tail.
	var echo := AudioEffectDelay.new()
	echo.dry = 1.0
	echo.tap1_active = true
	echo.tap1_delay_ms = 380.0
	echo.tap1_level_db = ECHO_DB
	echo.tap1_pan = -0.6
	echo.tap2_active = true
	echo.tap2_delay_ms = 820.0
	echo.tap2_level_db = ECHO_DB - 4.0
	echo.tap2_pan = 0.6
	echo.feedback_active = true
	echo.feedback_delay_ms = 1100.0
	echo.feedback_level_db = ECHO_DB - 6.0
	echo.feedback_lowpass = 2500.0
	AudioServer.add_bus_effect(idx, echo)
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
	_impacts = ImpactSounds.new()
	_impacts.name = "Impacts"
	_impacts.sounds = sounds
	add_child(_impacts)
	if _plume.stones != null:
		_impacts.frame = _plume.stones
		_plume.stones.impacted.connect(_impacts.on_impact)
	_ash = AshFall.new()
	_ash.name = "AshFall"
	_ash.sounds = sounds
	add_child(_ash)
	# In the plume's frame (+Y up), so the flakes fall down.
	_ash_visual = AshVisual.new()
	_plume.add_child(_ash_visual)


func _exit_tree() -> void:
	_alive.erase(self)
	_still()
	if is_instance_valid(_ash_visual):
		_ash_visual.queue_free()


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
	_ash_visual.update(_plume.to_local(cam.global_position), cam.global_position, _ash.level, _height, _ash_wind)
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
		# Ash only from the nearest plume: the one overhead, if any.
		var ash: float = _plume.ash_over(_plume.to_local(cam.global_position)) if rank == 0 else 0.0
		_ash.set_target(AshFall.ash_level(ash, sounds.ash_full))
		if ash > 0.0 and is_instance_valid(_planet):
			_ash_wind = _plume.global_basis.inverse() * _planet.wind_world_at(cam.global_position)
	_set_voice(rank)
	_hear(cam)


## Reads the schedule at the heard time and sets every sound.
func _hear(cam: Camera3D) -> void:
	var model: VolcanoPlumeModel = _plume.model
	var felt_range: float = maxf(sounds.quake_range_m, maxf(sounds.shock_range_m, sounds.tremor_range_m))
	_height = _plume.height_over_ground(_plume.to_local(cam.global_position)) if _dist < felt_range else INF
	_grounded = _height < GROUND_M
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
	_drive(_rumble, level_db(sounds.rumble_db + boost, Acoustics.gain_db(_dist, sounds.rumble_full_m,
			sounds.rumble_range_m, sounds.far_db), rumble_level(window, heard, sounds.build_up_s,
			sounds.rumble_before, sounds.rumble_rise_s), _air))
	_drive(_cracks, level_db(sounds.cracks_db + boost, Acoustics.gain_db(_dist, sounds.cracks_full_m,
			sounds.cracks_range_m, sounds.far_db), cracks_level(window, heard, sounds.build_up_s,
			sounds.cracks_fade_s), _air))
	var salt: int = model.volcano_seed ^ int(float(window.get("start_unix", 0.0)))
	var last: float = float(_played.get(model.volcano_key, NAN))
	var index: int = blast_due(window, heard, last, BLAST_GRACE_S, sounds.explosion_repeat_s, salt)
	if index >= 0:
		_played[model.volcano_key] = blast_time_of(window, index, sounds.explosion_repeat_s, salt)
		var drop: float = blast_drop_db(index, sounds.explosion_repeat_drop_db, salt)
		_blast(index, salt, boost + drop)
		# Its shock wave travels with its sound: felt now, as it is heard.
		if _grounded and _voice == 0 and _dist < sounds.shock_range_m:
			_shock = 1.0
			_shock_share = db_to_linear(drop) * falloff_share(_dist, sounds.shock_full_m, sounds.shock_range_m)
	_feel()


## Reads the schedule at the time the GROUND brings, and sets the shake of the view: rock carries a blast
## some ten times faster than air, so it is felt in the feet seconds before it is heard.
func _feel() -> void:
	_tremor = 0.0
	_ground_level = 0.0
	if _voice != 0 or not _grounded:
		return
	var model: VolcanoPlumeModel = _plume.model
	var felt: float = Acoustics.heard_time(VolcanoPlume.clock(), _dist, sounds.ground_speed_m_s)
	var window: Dictionary = window_at(model.profile, felt, sounds.build_up_s, model.volcano_seed,
			model.volcano_key, model.dormant)
	if _dist < sounds.quake_range_m:
		_feel_quake(window, felt)
	if _dist >= sounds.tremor_range_m:
		return
	_tremor = tremor_share(_dist, sounds.tremor_full_m, sounds.tremor_range_m)
	_ground_level = rumble_level(window, felt, sounds.build_up_s, sounds.rumble_before, sounds.rumble_rise_s)
	var salt: int = model.volcano_seed ^ int(float(window.get("start_unix", 0.0)))
	var last: float = float(_felt.get(model.volcano_key, NAN))
	var index: int = blast_due(window, felt, last, BLAST_GRACE_S, sounds.explosion_repeat_s, salt)
	if index >= 0:
		_felt[model.volcano_key] = blast_time_of(window, index, sounds.explosion_repeat_s, salt)
		_kick = db_to_linear(blast_drop_db(index, sounds.explosion_repeat_drop_db, salt))


## A quake of a strong eruption, at the time the ground brings it (before its sound would): starts the jolt
## and its short deep rumble.
func _feel_quake(window: Dictionary, felt: float) -> void:
	var model: VolcanoPlumeModel = _plume.model
	var salt: int = model.volcano_seed ^ int(float(window.get("start_unix", 0.0)))
	var last: float = float(_quaked.get(model.volcano_key, NAN))
	var index: int = quake_due(window, felt, last, BLAST_GRACE_S, sounds.quake_repeat_s, salt,
			sounds.quake_min_strength)
	if index < 0:
		return
	var at: float = quake_time_of(window, index, sounds.quake_repeat_s, salt)
	_quaked[model.volcano_key] = at
	_quake_len = quake_length(index, salt, sounds.quake_min_s, sounds.quake_max_s)
	_quake_age = felt - at
	_quake_share = falloff_share(_dist, sounds.quake_full_m, sounds.quake_range_m)
	print("[VolcanoSound] quake %s d=%.1f km length=%.1f s share=%.2f" % [
			model.volcano_key, _dist / 1000.0, _quake_len, _quake_share])
	# Through the ground: no air to cross, the bus low-pass still makes it deeper with distance.
	_play_take(pick_take(sounds.quakes, index, salt, 823), level_db(sounds.quake_db, Acoustics.gain_db(_dist,
			sounds.quake_full_m, sounds.quake_range_m, sounds.far_db), 1.0, 1.0))


## Moves the view with the ground, every frame: the tremor of the eruption, the kick of each blast, the quakes
## and the shock waves, through the camera's frustum offsets -- its transform, which the player's look
## drives, is left alone.
func _shake(cam: Camera3D, delta: float) -> void:
	_kick = move_toward(_kick, 0.0, delta / sounds.tremor_kick_s)
	_shock = move_toward(_shock, 0.0, delta / sounds.shock_s)
	_quake_age += delta
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var reach: float = _tremor * (sounds.tremor_m * _ground_level * swell(t) + sounds.tremor_kick_m * _kick * _kick)
	reach += sounds.quake_m * _quake_share * quake_envelope(_quake_age, _quake_len)
	reach += sounds.shock_m * _shock_share * _shock * _shock
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


## The blast [param index] of an eruption, [param extra_db] over the nominal level: near, the explosion (a
## take that is not the last one); far, its shock wave (a take drawn from [param salt]); between
## blast_wave_from_m and blast_wave_to_m, both, faded at equal power.
func _blast(index: int, salt: int, extra_db: float) -> void:
	var delay: float = Acoustics.delay_s(_dist, sounds.sound_speed_m_s)
	var distance_db: float = Acoustics.gain_db(_dist, sounds.explosion_full_m, sounds.explosion_range_m, sounds.far_db)
	var far: float = wave_share(_dist, sounds.blast_wave_from_m, sounds.blast_wave_to_m)
	var near_db: float = level_db(sounds.explosion_db + extra_db, distance_db, cos(far * PI * 0.5), _air)
	var wave_db: float = level_db(sounds.blast_wave_db + extra_db, distance_db, sin(far * PI * 0.5), _air)
	print("[VolcanoSound] explosion %s d=%.1f km delay=%.0f s near=%.0f dB wave=%.0f dB" % [
			_plume.model.volcano_key, _dist / 1000.0, delay, near_db, wave_db])
	if near_db > QUIET_DB:
		_last_take = SurfaceSounds.pick_from(sounds.explosions, _last_take)
		_play_take(_last_take, near_db)
	_play_take(pick_take(sounds.blast_waves, index, salt, 824), wave_db)


## One take on the proxy at [param db], through this volcano's bus (its distance low-pass), freed when over.
func _play_take(take: AudioStream, db: float) -> void:
	if take == null or db <= QUIET_DB:
		return
	var player := AudioStreamPlayer3D.new()
	Sfx3D.configure(player, take, db, 1.0, 0.0, Sfx3D.Attenuation.FLAT)
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
	_ground_level = 0.0
	_tremor = 0.0
	_grounded = false
	if _ash != null:
		_ash.set_target(0.0)
	for player: AudioStreamPlayer3D in [_steam, _rumble, _cracks]:
		if player != null and player.playing:
			player.stop()
