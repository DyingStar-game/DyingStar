class_name DustWallSound
extends Node3D
## The sound of one dust wall (WeatherPhenomena), for the listener where it stands against the wall as
## WeatherRelief has it (wall_effect: ahead of the front, behind it, along it). Takes by WarpZone in
## assets/_universe/audio/sfx/environment/weather/:
##   - approach (dust-wall-approach-*, 20 s): a far rumble growing, heard from APPROACH_FAR_M down to the front,
##     from the nearest point of the front, louder and brighter as it nears (a low-pass on its own bus);
##   - front (dust-wall-front-*, 15 s): the gust front hitting, once each time the front crosses the listener
##     (it runs over a standing player; a flying one crosses it), one take per wall;
##   - inside (dust-wall-inside-loop-*, 30 s): the storm all round, behind the front, as loud as the wall's dust
##     there (its strength, thinning over its depth), fading as the wall thins or the listener leaves it.
## Both beds loop by chaining takes with a crossfade (the seam never heard) and glide to their level: the
## approach hands over to the inside without a pop. The takes follow from the wall's id: the same wall sounds
## the same for every player. Client only (Sfx3D.muted).
##
## Lives in WeatherPhenomena's frame (the body's), put at the listener every frame (advance).

const APPROACH_TAKES: Array[String] = [
	"res://assets/_universe/audio/sfx/environment/weather/dust-wall-approach-1.ogg",
	"res://assets/_universe/audio/sfx/environment/weather/dust-wall-approach-2.ogg",
	"res://assets/_universe/audio/sfx/environment/weather/dust-wall-approach-3.ogg",
	"res://assets/_universe/audio/sfx/environment/weather/dust-wall-approach-4.ogg",
]
const FRONT_TAKES: Array[String] = [
	"res://assets/_universe/audio/sfx/environment/weather/dust-wall-front-1.ogg",
	"res://assets/_universe/audio/sfx/environment/weather/dust-wall-front-2.ogg",
	"res://assets/_universe/audio/sfx/environment/weather/dust-wall-front-3.ogg",
	"res://assets/_universe/audio/sfx/environment/weather/dust-wall-front-4.ogg",
]
const INSIDE_TAKES: Array[String] = [
	"res://assets/_universe/audio/sfx/environment/weather/dust-wall-inside-loop-1.ogg",
	"res://assets/_universe/audio/sfx/environment/weather/dust-wall-inside-loop-2.ogg",
	"res://assets/_universe/audio/sfx/environment/weather/dust-wall-inside-loop-3.ogg",
]
## The approach's own bus (under SFX): its low-pass follows the nearest wall's distance.
const APPROACH_BUS := &"DustWallApproach"
## Under this gain (linear) a bed is stopped.
const SILENT := 0.001

## Loudness (dB) of the approach rumble at the front, of a full-strength wall.
@export var approach_db: float = -2.0
## Distance (m) from the front at which the approach rumble starts to be heard; it grows from there to the front.
@export var approach_far_m: float = 8000.0
## The approach's low-pass (Hz): at the front (bright) and at approach_far_m (a dull rumble).
@export var approach_cutoff_hz: Vector2 = Vector2(12000.0, 600.0)
## Loudness (dB) of the gust front's take as it passes, for a full-strength wall.
@export var front_db: float = 0.0
## Shortest time (s) between two front takes of the same wall (a listener hovering on the line).
@export var front_again_s: float = 20.0
## Loudness (dB) of the storm all round inside a full-strength wall, right behind its front.
@export var inside_db: float = 0.0
## How far ahead of the front (m) the storm all round starts to be heard, rising to full at the front:
## higher = a longer swell as the wall comes on, 0 = it starts at the line.
@export var inside_lead_m: float = 400.0
## How fast (per second, share of full level) the beds glide to their level: higher = quicker changes.
@export var glide_per_s: float = 0.8
## Crossfade (s) between two takes of a bed.
@export var crossfade_s: float = 3.0
## How far (m) from the listener the approach rumble is placed, toward the nearest point of the front.
@export var proxy_m: float = 30.0

var _seed: int = 0
var _approach: Bed = null
var _inside: Bed = null
var _front: AudioStreamPlayer3D = null
var _front_streams: Array[AudioStream] = []
var _was_ahead: int = 0  # 1 ahead of the front, -1 behind it, 0 not yet known
var _front_at: float = -INF
static var _approach_owner: int = 0  # the instance id of the wall that set the approach bus's cutoff
static var _approach_owner_m: float = INF


## One looping bed: two players chaining takes, each faded in and out over the crossfade. Positional
## (AudioStreamPlayer3D: the approach, from the front) or all round the listener (AudioStreamPlayer: the
## inside; at a point on the listener, a 3D player swung from ear to ear as the head turned, 2026-11-25).
class Bed extends RefCounted:
	var players: Array = []  # AudioStreamPlayer3D or AudioStreamPlayer: the members both have are used
	var positional: bool = true
	var streams: Array[AudioStream] = []
	var gain: float = 0.0
	var take: int = 0
	var take_seed: int = 0
	var current: int = -1

	func _init(host: Node3D, paths: Array[String], bed_seed: int, bus: StringName, is_positional: bool) -> void:
		take_seed = bed_seed
		positional = is_positional
		for path: String in paths:
			if ResourceLoader.exists(path):
				streams.append(load(path) as AudioStream)
		for k in 2:
			var player: Node
			if positional:
				var p3 := AudioStreamPlayer3D.new()
				Sfx3D.configure(p3, null, -80.0, 1.0, 0.0, Sfx3D.Attenuation.FLAT)
				player = p3
			else:
				var p2 := AudioStreamPlayer.new()
				p2.bus = Sfx3D.SFX_BUS
				p2.volume_db = -80.0
				player = p2
			if bus != &"":
				player.set("bus", bus)
			host.add_child(player)
			players.append(player)

	## Glide toward [param target] (linear gain), at [param base_db] for gain 1, chaining takes with a
	## [param xfade] s crossfade.
	func update(target: float, base_db: float, rate: float, xfade: float, delta: float) -> void:
		gain = move_toward(gain, clampf(target, 0.0, 1.0), rate * delta)
		if streams.is_empty():
			return
		if gain < DustWallSound.SILENT:
			for p in players:
				if p.playing:
					p.stop()
			current = -1
			return
		var playing: Variant = players[current] if current >= 0 else null
		if playing == null or not playing.playing or playing.get_playback_position() > playing.stream.get_length() - xfade:
			current = (current + 1) % 2 if current >= 0 else 0
			var next: Variant = players[current]
			next.stream = streams[int(WeatherHash.unit(WeatherHash.mix(take_seed, take, 13, 1)) * streams.size()) % streams.size()]
			next.play()
			take += 1
		for p in players:
			if not p.playing:
				continue
			var at: float = p.get_playback_position()
			var envelope := clampf(at / xfade, 0.0, 1.0) * clampf((p.stream.get_length() - at) / xfade, 0.0, 1.0)
			var db := base_db + linear_to_db(maxf(gain * envelope, 1e-4))
			p.volume_db = db
			if positional:
				p.max_db = db


## For the wall of id [param id].
func setup(id: int) -> void:
	_seed = id
	_approach = Bed.new(self, APPROACH_TAKES, WeatherHash.mix(id, 1, 0, 0), ensure_approach_bus(), true)
	_inside = Bed.new(self, INSIDE_TAKES, WeatherHash.mix(id, 2, 0, 0), &"", false)
	for path: String in FRONT_TAKES:
		if ResourceLoader.exists(path):
			_front_streams.append(load(path) as AudioStream)
	_front = AudioStreamPlayer3D.new()
	Sfx3D.configure(_front, null, front_db, 1.0, 0.0, Sfx3D.Attenuation.FLAT)
	add_child(_front)


func _exit_tree() -> void:
	if _approach_owner == get_instance_id():
		_approach_owner = 0
		_approach_owner_m = INF


## Every frame: [param wall] as the weather has it, the listener at [param eye] (this node's parent frame, the
## body's) on a planet of [param radius_m], [param over_ground_m] over the ground. Inside the wall only within
## its height (WeatherRelief.wall_tall, faded over WALL_TOP_FADE_M): over it, the listener hears the wall from
## outside, the rumble from its top below.
func advance(delta: float, wall: Dictionary, eye: Vector3, radius_m: float, over_ground_m: float) -> void:
	if Sfx3D.muted() or _approach == null:
		return
	position = eye
	var up := eye.normalized()
	var at := HEALPix.vec2lonlat(up)
	var d := WeatherRelief.offset_m(Vector2(wall["lon"], wall["lat"]), at, radius_m)
	var way := Vector2(wall["east"], wall["north"])
	var across := Vector2(-way.y, way.x)
	var along := d.dot(across)
	var behind := WeatherRelief.wall_behind_m(wall, at, radius_m)  # from the front as drawn, not the straight line
	var half: float = float(wall["length_m"]) * 0.5
	var strength: float = float(wall["strength"])
	var inside_front := absf(along) <= half
	var tall := WeatherRelief.wall_tall_at(wall, behind)  # its tail sinks as it thins
	var within := 1.0 - smoothstep(tall, tall + WeatherRelief.WALL_TOP_FADE_M, over_ground_m)  # within its height
	var gap := maxf(over_ground_m - tall, 0.0)  # how far over its top
	var in_box := behind >= 0.0 and behind <= WeatherRelief.wall_reach_m(float(wall["depth_m"])) and inside_front
	# The nearest point of the front (along the ground) and how far the wall is (m, its top's height included).
	var to_front := across * clampf(along, -half, half) - d
	var flat := 0.0 if in_box else to_front.length()
	var distance := sqrt(flat * flat + gap * gap)
	var approach := strength * (1.0 - smoothstep(0.0, approach_far_m, distance)) * (1.0 - within if in_box else 1.0)
	var share := float(WeatherRelief.wall_effect(wall, at, radius_m)[1]) / WeatherRelief.WALL_TAU * within
	# The storm's roar is heard from inside_lead_m ahead of the front, full at it: it swells as the wall comes
	# on instead of starting at the line (heard 2026-11-28).
	if inside_front and behind < WeatherRelief.WALL_DUST_RAMP_M:
		share = maxf(share, strength * within * smoothstep(-inside_lead_m, 0.0, behind)
				* (1.0 - smoothstep(half * 0.8, half, absf(along))))
	# The approach from the nearest point of the front, the inside all round.
	var axes: Array = Planet.local_axes(up)
	var toward: Vector3 = (axes[0] as Vector3) * to_front.x + (axes[1] as Vector3) * to_front.y
	if in_box:
		toward = -up  # over the wall: its top below
	var proxy := toward.normalized() * proxy_m if toward.length() > 1.0 else Vector3.ZERO
	for p: Variant in _approach.players:
		(p as Node3D).position = proxy
	_approach.update(approach, approach_db, glide_per_s, crossfade_s, delta)
	_inside.update(share, inside_db, glide_per_s, crossfade_s, delta)
	if approach > SILENT and (_approach_owner == 0 or _approach_owner == get_instance_id() or distance < _approach_owner_m):
		_approach_owner = get_instance_id()
		_approach_owner_m = distance
		var idx := AudioServer.get_bus_index(APPROACH_BUS)
		if idx >= 0:
			(AudioServer.get_bus_effect(idx, 0) as AudioEffectLowPassFilter).cutoff_hz = lerpf(approach_cutoff_hz.x,
					approach_cutoff_hz.y, clampf(distance / approach_far_m, 0.0, 1.0))
	elif _approach_owner == get_instance_id():
		_approach_owner = 0
		_approach_owner_m = INF
	_cross_front(behind, inside_front and within > 0.5, strength)


## The gust front's take, when the listener has just crossed the front (either way), within its length.
func _cross_front(behind: float, inside_front: bool, strength: float) -> void:
	var side := 1 if behind < 0.0 else -1
	var crossed := _was_ahead != 0 and side != _was_ahead and inside_front
	_was_ahead = side
	var now := Time.get_ticks_msec() / 1000.0
	if not crossed or _front_streams.is_empty() or now - _front_at < front_again_s or strength < 0.05:
		return
	_front_at = now
	_front.stream = _front_streams[int(WeatherHash.unit(WeatherHash.mix(_seed, 3, 0, 0)) * _front_streams.size())
			% _front_streams.size()]
	var db := front_db + linear_to_db(clampf(strength, 1e-3, 1.0))
	_front.volume_db = db
	_front.max_db = db
	_front.play()


## The approach's bus, made on first use under SFX with a low-pass (effect 0).
static func ensure_approach_bus() -> StringName:
	if AudioServer.get_bus_index(APPROACH_BUS) >= 0:
		return APPROACH_BUS
	var idx: int = AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, APPROACH_BUS)
	AudioServer.set_bus_send(idx, Sfx3D.SFX_BUS)
	var filter := AudioEffectLowPassFilter.new()
	filter.cutoff_hz = 2000.0
	AudioServer.add_bus_effect(idx, filter)
	return APPROACH_BUS
