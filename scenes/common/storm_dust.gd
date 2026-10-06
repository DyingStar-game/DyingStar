class_name StormDust
extends RefCounted
## The dust the wind raises as the player sees it — client side, from the weather the planet samples
## (Planet.weather_at, wind_world_at), through the same DustEmitter the footsteps and the tyres use, so
## the colour is the ground's own and the grains obey the same air. The SKY's part of a storm — the
## veil thickening, the star dimming — is WeatherSky's; this is what flies past your visor and over
## the ground around you. Three populations, each with its own cause:
##
## - CLOUDS past the visor, born upwind and carried by the wind: from the sampler's dust optical depth
##   τ (0 = clear air, 2 = a storm with 100 m of visibility); puffs per second from TAU_MIN to TAU_FULL.
## - A low HAZE of veils laid along the wind just over the ground, all around: from the WIND alone,
##   once it lifts grains off this ground (saltation_rate), on the plains as in a storm.
## - SALTATION streaks: grains hopping along the ground at the wind's speed, drawn as streaks (the
##   process shader stretches them along their motion), born upwind at ground height, from the same
##   wind — the sand that flies at your boots in any good blow.
## - WISPS: the sand that SMOKES off the ground — veils born on the surface, carried by the wind and
##   rising with it, stretched along their motion, swelling as they climb then flattening into the
##   wind (the drag relaxes their rise); the long tilted plumes a blow lifts off every crest.
##
## The ground's own family sizes every puff (SurfaceDust.amount): over rock little flies, over sand a
## lot. Grains and sheets stand on the REAL ground (PlanetData.crack_aware_surface_dist: relief and
## canyons), the client having no terrain collision to ask.

## How often the weather is read (s): it changes over minutes, the sampler costs tens of microseconds.
const SAMPLE_S: float = 0.5
## Dust optical depth under which no cloud flies, and from which the rate is full.
const TAU_MIN: float = 0.15
const TAU_FULL: float = 2.0
## Cloud puffs per second in a full storm.
const RATE_FULL: float = 40.0
## Where the clouds are born: this far upwind of the camera, spread this much sideways and up and down.
const UPWIND_M: float = 12.0
const SPREAD_M: float = 8.0
const HEIGHT_SPREAD_M: float = 2.5
## Under this wind (m/s along the ground) the dust hangs around the camera instead of streaming.
const CALM_MS: float = 1.5
## A storm's grain cloud at birth (m), and how many a puff holds.
const GRAIN_SIZE_M: float = 2.2
const GRAINS_PER_PUFF: int = 2
## Most puffs of one population in one frame: after a hitch, a thinner second rather than a wall.
const MAX_PUFFS_PER_FRAME: int = 8
const CAPACITY: int = 256
const LIFETIME_S: float = 3.0
## Under this air density (kg/m³) nothing flies: a storm's grains are not met in orbit.
const MIN_AIR_KG_M3: float = 0.05

## The low haze: sheets this big (m), born this far around the camera (upwind-biased), this high over
## the ground, at most this many a second once the wind lifts the ground fully (twice its threshold).
const HAZE_SIZE_M: float = 6.0
const HAZE_RING_M: float = 24.0
const HAZE_HEIGHT_M: float = 1.2
const HAZE_RATE_FULL: float = 7.0
const HAZE_OPACITY: float = 0.2

## The saltation streaks: this big across (m), stretched along their motion by the process shader
## (STREAK_STRETCH_PER_MS: at 20 m/s 2.6 times longer than wide), hopping this high (m), at this share
## of the wind's speed, born this far upwind, living this long; at most this many a second.
const STREAK_SIZE_M: float = 0.35
const STREAK_STRETCH_PER_MS: float = 0.08
const STREAK_HOP_M: float = 0.35
const STREAK_SPEED_SHARE: float = 0.85
const STREAK_UPWIND_M: float = 9.0
const STREAK_SPREAD_M: float = 7.0
const STREAK_LIFETIME_S: float = 0.8
const STREAK_RATE_FULL: float = 80.0
const STREAK_CAPACITY: int = 320
## The clouds past the visor stretch a little with the wind too: streams, not balls.
const CLOUD_STRETCH_PER_MS: float = 0.03

## The wisps: veils this big at birth (m), stretched this much per m/s, born on the ground this far
## upwind over this spread, rising at this speed (m/s) while carried at this share of the wind, living
## this long (they swell meanwhile: SurfaceDust.air_growth), this faint; at most this many a second.
const WISP_SIZE_M: float = 1.8
const WISP_STRETCH_PER_MS: float = 0.12
const WISP_UPWIND_M: float = 10.0
const WISP_SPREAD_M: float = 12.0
const WISP_RISE_MS: float = 0.9
const WISP_SPEED_SHARE: float = 0.7
const WISP_LIFETIME_S: float = 3.5
const WISP_OPACITY: float = 0.3
const WISP_RATE_FULL: float = 14.0
const WISP_CAPACITY: int = 256

var _player: Player = null
var _emitter: DustEmitter = null
var _streaks: DustEmitter = null
var _wisps: DustEmitter = null
var _age: float = INF  # since the last weather reading: INF = read now
var _rate: float = 0.0
var _haze_rate: float = 0.0
var _streak_rate: float = 0.0
var _wisp_rate: float = 0.0
var _wind: Vector3 = Vector3.ZERO
var _owed: float = 0.0  # puffs owed, fractional, per population
var _haze_owed: float = 0.0
var _streak_owed: float = 0.0
var _wisp_owed: float = 0.0


func _init(player: Player, dust: SurfaceDust) -> void:
	_player = player
	if dust != null:
		_emitter = DustEmitter.new(player, dust, CAPACITY, LIFETIME_S)
		_emitter.set_stretch(CLOUD_STRETCH_PER_MS)
		_streaks = DustEmitter.new(player, dust, STREAK_CAPACITY, STREAK_LIFETIME_S)
		_streaks.set_stretch(STREAK_STRETCH_PER_MS)
		_wisps = DustEmitter.new(player, dust, WISP_CAPACITY, WISP_LIFETIME_S)
		_wisps.set_stretch(WISP_STRETCH_PER_MS)


## Once a frame on the client. [param family] is the ground under the player (the footsteps' probe).
func update(delta: float, family: StringName) -> void:
	if _emitter == null or not DustEmitter.enabled() or not is_instance_valid(_player) \
			or not _player.is_inside_tree():
		return
	_age += delta
	if _age >= SAMPLE_S:
		_age = 0.0
		_resample()
	if _rate <= 0.0 and _haze_rate <= 0.0 and _streak_rate <= 0.0 and _wisp_rate <= 0.0:
		_owed = 0.0
		_haze_owed = 0.0
		_streak_owed = 0.0
		_wisp_owed = 0.0
		return
	var camera: Camera3D = _player.get_viewport().get_camera_3d()
	if camera == null:
		return
	var up: Vector3 = _player.global_basis.y.normalized()
	var eye: Vector3 = camera.global_position
	_owed += _rate * delta
	for _i in _take(_owed):
		_owed -= 1.0
		_emitter.puff(birth_point(eye, _wind, up, _jitter()), family, 1.0, _wind, GRAINS_PER_PUFF, 0.5,
				GRAIN_SIZE_M)
	if _haze_rate <= 0.0 and _streak_rate <= 0.0 and _wisp_rate <= 0.0:
		return
	var planet: Planet = Planet.of(_player)
	if planet == null:
		return
	_haze_owed += _haze_rate * delta
	for _i in _take(_haze_owed):
		_haze_owed -= 1.0
		var around: Vector3 = birth_point(eye, _wind, up, _jitter(), HAZE_RING_M * 0.5, HAZE_RING_M, 0.0)
		# Through the stretched emitter: a sheet is a veil laid along the wind, never a ball.
		_wisps.puff(on_the_ground(planet, around, up, HAZE_HEIGHT_M * randf_range(0.4, 1.2)), family,
				HAZE_OPACITY, _wind * 0.9, 1, 1.5, HAZE_SIZE_M)
	_streak_owed += _streak_rate * delta
	for _i in _take(_streak_owed):
		_streak_owed -= 1.0
		var at: Vector3 = birth_point(eye, _wind, up, _jitter(), STREAK_UPWIND_M, STREAK_SPREAD_M, 0.0)
		var hop: Vector3 = up * STREAK_HOP_M * randf_range(0.4, 1.0)
		_streaks.puff(on_the_ground(planet, at, up, randf_range(0.03, 0.25)), family, 1.0,
				_wind * STREAK_SPEED_SHARE + hop, 1, 0.4, STREAK_SIZE_M)
	_wisp_owed += _wisp_rate * delta
	for _i in _take(_wisp_owed):
		_wisp_owed -= 1.0
		var foot: Vector3 = birth_point(eye, _wind, up, _jitter(), WISP_UPWIND_M, WISP_SPREAD_M, 0.0)
		var rise: Vector3 = up * WISP_RISE_MS * randf_range(0.5, 1.2)
		_wisps.puff(on_the_ground(planet, foot, up, randf_range(0.0, 0.3)), family, WISP_OPACITY,
				_wind * WISP_SPEED_SHARE + rise, 1, 0.8, WISP_SIZE_M)


## Free the clouds. Called by the owner when the body goes.
func release() -> void:
	if _emitter != null:
		_emitter.release()
	if _streaks != null:
		_streaks.release()
	if _wisps != null:
		_wisps.release()


## Puffs per second for a dust optical depth [param dust_tau]: none under TAU_MIN, RATE_FULL from
## TAU_FULL, straight between.
static func rate_for(dust_tau: float) -> float:
	if dust_tau < TAU_MIN:
		return 0.0
	return RATE_FULL * clampf((dust_tau - TAU_MIN) / (TAU_FULL - TAU_MIN), 0.0, 1.0)


## How much of its ground a wind of [param wind_ms] lifts, 0..1, for a ground whose grains start to
## move at [param threshold_ms] (ClimateProfile.v10_threshold_m_s): nothing under the threshold, then
## Owen's saltation flux, ∝ v³ (1 - v_t²/v²), scaled to 1 at twice the threshold and capped there.
## The plains blow sand at any good wind; a storm only blows more of it.
static func saltation_rate(wind_ms: float, threshold_ms: float) -> float:
	if threshold_ms <= 0.0 or wind_ms <= threshold_ms:
		return 0.0
	var v: float = wind_ms
	var vt: float = threshold_ms
	return clampf((v * v * v - vt * vt * v) / (6.0 * vt * vt * vt), 0.0, 1.0)


## Where a grain is born for a camera at [param camera_pos] in a [param wind] (world, m/s) with the local
## [param up]: [param upwind_m] upwind along the ground, then [param jitter] (each part -1..1) across
## [param spread_m] sideways, half that along the wind, and [param height_spread_m] up and down. In
## near-calm air, the same spread all around the camera instead: the dust hangs.
static func birth_point(camera_pos: Vector3, wind: Vector3, up: Vector3, jitter: Vector3,
		upwind_m: float = UPWIND_M, spread_m: float = SPREAD_M, height_spread_m: float = HEIGHT_SPREAD_M) -> Vector3:
	var n: Vector3 = up.normalized() if not up.is_zero_approx() else Vector3.UP
	var flat: Vector3 = wind - n * wind.dot(n)
	var speed: float = flat.length()
	if speed < CALM_MS:
		var a: Vector3 = n.cross(Vector3.RIGHT)
		if a.length_squared() < 1e-6:
			a = n.cross(Vector3.FORWARD)
		a = a.normalized()
		var b: Vector3 = n.cross(a)
		return camera_pos + a * jitter.x * spread_m + b * jitter.z * spread_m + n * jitter.y * height_spread_m
	var dir: Vector3 = flat / speed
	var side: Vector3 = n.cross(dir)
	return camera_pos - dir * upwind_m + side * jitter.x * spread_m + dir * jitter.z * spread_m * 0.5 \
			+ n * jitter.y * height_spread_m


## [param near] put on the real ground of [param planet] along the radial through it, [param height_m]
## over it: the relief and the canyons (crack_aware_surface_dist), where the client has no collision
## to ask. [param up] is only a fallback when the point sits at the planet's centre.
static func on_the_ground(planet: Planet, near: Vector3, up: Vector3, height_m: float) -> Vector3:
	if planet == null or planet.planet_data == null:
		return near + up * height_m
	var dir: Vector3 = planet.local_dir_of(near)
	if dir.is_zero_approx():
		return near + up * height_m
	var ground: float = planet.planet_data.crack_aware_surface_dist(dir)
	return planet.to_global(dir * (ground + height_m))


static func _jitter() -> Vector3:
	return Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))


## How many puffs an owed count pays for this frame, capped.
static func _take(owed: float) -> int:
	return clampi(int(owed), 0, MAX_PUFFS_PER_FRAME)


func _resample() -> void:
	_rate = 0.0
	_haze_rate = 0.0
	_streak_rate = 0.0
	_wisp_rate = 0.0
	_wind = Vector3.ZERO
	if _player.floating:
		return  # in free flight there is no ground to lift
	var planet: Planet = Planet.of(_player)
	if planet == null:
		return
	var sample: Dictionary = planet.weather_at(_player.global_position)
	if sample.is_empty():
		return
	if float(sample.get("air_density_kg_m3", 0.0)) < MIN_AIR_KG_M3:
		return
	_rate = rate_for(float(sample.get("dust_tau", 0.0)))
	_wind = planet.wind_world_at(_player.global_position)
	var profile: ClimateProfile = planet.climate_profile()
	var lifted: float = saltation_rate(_wind.length(), profile.v10_threshold_m_s if profile != null else 0.0)
	_haze_rate = HAZE_RATE_FULL * lifted
	_streak_rate = STREAK_RATE_FULL * lifted
	_wisp_rate = WISP_RATE_FULL * lifted
