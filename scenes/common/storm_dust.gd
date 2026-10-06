class_name StormDust
extends RefCounted
## The dust of a storm as the player sees it: grains streaming past the camera, born upwind of it and
## carried by the wind — client side, from the weather the planet samples (Planet.weather_at), through
## the same DustEmitter the footsteps and the tyres use, so the colour is the ground's own and the
## grains obey the same air. The SKY's part of a storm — the veil thickening, the star dimming — is
## WeatherSky's; this is what flies past your visor.
##
## Rate: the sampler's dust optical depth τ says how much dust the storm holds over this ground (0 =
## none, 2 = a storm with 100 m of visibility); puffs per second grow from TAU_MIN to TAU_FULL. Where:
## a ring UPWIND_M upwind of the camera, at eye height give or take, so the grains cross the view within
## a second at storm winds; in near-calm air (a dust cloud without wind) they are born all around the
## camera and hang. The ground's own family sizes every puff (SurfaceDust.amount): a storm over rock
## throws little, over sand a lot.

## How often the weather is read (s): it changes over minutes, the sampler costs tens of microseconds.
const SAMPLE_S: float = 0.5
## Dust optical depth under which nothing flies, and from which the rate is full.
const TAU_MIN: float = 0.15
const TAU_FULL: float = 2.0
## Puffs per second in a full storm.
const RATE_FULL: float = 40.0
## Where the grains are born: this far upwind of the camera, spread this much sideways and up and down.
const UPWIND_M: float = 12.0
const SPREAD_M: float = 8.0
const HEIGHT_SPREAD_M: float = 2.5
## Under this wind (m/s along the ground) the dust hangs around the camera instead of streaming.
const CALM_MS: float = 1.5
## A storm's grain cloud at birth (m), and how many a puff holds.
const GRAIN_SIZE_M: float = 2.2
const GRAINS_PER_PUFF: int = 2
## Most puffs in one frame: after a hitch, a thinner second rather than a wall.
const MAX_PUFFS_PER_FRAME: int = 8
const CAPACITY: int = 256
const LIFETIME_S: float = 3.0

var _player: Player = null
var _emitter: DustEmitter = null
var _age: float = INF  # since the last weather reading: INF = read now
var _rate: float = 0.0
var _wind: Vector3 = Vector3.ZERO
var _owed: float = 0.0  # puffs owed, fractional


func _init(player: Player, dust: SurfaceDust) -> void:
	_player = player
	if dust != null:
		_emitter = DustEmitter.new(player, dust, CAPACITY, LIFETIME_S)


## Once a frame on the client. [param family] is the ground under the player (the footsteps' probe).
func update(delta: float, family: StringName) -> void:
	if _emitter == null or not DustEmitter.enabled() or not is_instance_valid(_player) \
			or not _player.is_inside_tree():
		return
	_age += delta
	if _age >= SAMPLE_S:
		_age = 0.0
		_resample()
	if _rate <= 0.0:
		_owed = 0.0
		return
	var camera: Camera3D = _player.get_viewport().get_camera_3d()
	if camera == null:
		return
	_owed += _rate * delta
	var puffs: int = mini(int(_owed), MAX_PUFFS_PER_FRAME)
	_owed -= float(puffs)
	if puffs <= 0:
		return
	var up: Vector3 = _player.global_basis.y.normalized()
	for _i in puffs:
		var jitter := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
		_emitter.puff(birth_point(camera.global_position, _wind, up, jitter), family, 1.0, _wind,
				GRAINS_PER_PUFF, 0.5, GRAIN_SIZE_M)


## Free the cloud. Called by the owner when the body goes.
func release() -> void:
	if _emitter != null:
		_emitter.release()


## Puffs per second for a dust optical depth [param dust_tau]: none under TAU_MIN, RATE_FULL from
## TAU_FULL, straight between.
static func rate_for(dust_tau: float) -> float:
	if dust_tau < TAU_MIN:
		return 0.0
	return RATE_FULL * clampf((dust_tau - TAU_MIN) / (TAU_FULL - TAU_MIN), 0.0, 1.0)


## Where a grain is born for a camera at [param camera_pos] in a [param wind] (world, m/s) with the local
## [param up]: UPWIND_M upwind along the ground, then [param jitter] (each part -1..1) across SPREAD_M
## sideways, half that along the wind, and HEIGHT_SPREAD_M up and down. In near-calm air, the same
## spread all around the camera instead: the dust hangs.
static func birth_point(camera_pos: Vector3, wind: Vector3, up: Vector3, jitter: Vector3) -> Vector3:
	var n: Vector3 = up.normalized() if not up.is_zero_approx() else Vector3.UP
	var flat: Vector3 = wind - n * wind.dot(n)
	var speed: float = flat.length()
	if speed < CALM_MS:
		var a: Vector3 = n.cross(Vector3.RIGHT)
		if a.length_squared() < 1e-6:
			a = n.cross(Vector3.FORWARD)
		a = a.normalized()
		var b: Vector3 = n.cross(a)
		return camera_pos + a * jitter.x * SPREAD_M + b * jitter.z * SPREAD_M + n * jitter.y * HEIGHT_SPREAD_M
	var dir: Vector3 = flat / speed
	var side: Vector3 = n.cross(dir)
	return camera_pos - dir * UPWIND_M + side * jitter.x * SPREAD_M + dir * jitter.z * SPREAD_M * 0.5 \
			+ n * jitter.y * HEIGHT_SPREAD_M


func _resample() -> void:
	_rate = 0.0
	_wind = Vector3.ZERO
	if _player.floating:
		return  # in free flight there is no ground to lift
	var planet: Planet = Planet.of(_player)
	if planet == null:
		return
	var sample: Dictionary = planet.weather_at(_player.global_position)
	if sample.is_empty():
		return
	_rate = rate_for(float(sample.get("dust_tau", 0.0)))
	if _rate > 0.0:
		_wind = planet.wind_world_at(_player.global_position)
