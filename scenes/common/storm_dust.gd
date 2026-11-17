class_name StormDust
extends RefCounted
## The dust the wind raises as the player sees it — client side, from the weather the planet samples
## (Planet.weather_at, wind_world_at), through the same DustEmitter the footsteps and the tyres use, so
## the colour is the ground's own and the grains obey the same air. The SKY's part of a storm — the
## veil thickening, the star dimming — is WeatherSky's; this is what flies past your visor and over
## the ground around you. Three populations, each with its own cause (the low veils laid over the
## ground went on 2026-10-08: the ray-marched dust layer, aerial_perspective.gdshader, is that haze):
##
## - CLOUDS past the visor, born upwind and carried by the wind: from the sampler's dust optical depth
##   τ (0 = clear air, 2 = a storm with 100 m of visibility); puffs per second from TAU_MIN to TAU_FULL.
## - SALTATION streaks: grains hopping along the ground at the wind's speed, drawn as streaks (the
##   process shader stretches them along their motion), born upwind at ground height, from the same
##   wind — the sand that flies at your boots in any good blow.
## - WISPS: the sand that SMOKES off the ground — thin sheets born on the surface, carried by the wind and
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
## Over this height above the real ground (m) no dust is drawn: the grains are born around the eye at
## ground level, and from a ship or a god-mode flight high up they are under a pixel. Below it, floating
## or not, the wind still lifts the ground (god mode is floating: the dust stopped at 11 m, 2026-10-09).
const VIEW_HEIGHT_MAX_M: float = 150.0
## Under this wind (m/s along the ground) the dust hangs around the camera instead of streaming.
const CALM_MS: float = 1.5
## The turbulence intensity of the wind near the ground (the spread of the instant wind around its
## mean, as a share of it: 0.2 over open flats, 0.3 over rough ground). The gusts over the threshold
## lift sand while the mean wind is still under it.
const GUST_INTENSITY: float = 0.25
## The gusts' spread is integrated over this many standard deviations each side, in GUST_TAPS taps.
const GUST_SPAN_SIGMA: float = 3.5
const GUST_TAPS: int = 29
## The film of fine dust settled on every ground, rock included (the storms lay it down, nothing binds
## it): the first breeze lifts some of it, more as the wind grows, up to FILM_MAX of a full blow with
## FILM_SCALE_MS the wind that lifts 63 % of that. Under the sand's threshold it is all there is: with
## the threshold alone a rock plain at 25 km/h stayed dead still (2026-10-09).
const FILM_MAX: float = 0.08
const FILM_SCALE_MS: float = 6.0
## A storm's grain cloud at birth (m), and how many a puff holds.
const GRAIN_SIZE_M: float = 2.2
const GRAINS_PER_PUFF: int = 2
## Most puffs of one population in one frame: after a hitch, a thinner second rather than a wall.
const MAX_PUFFS_PER_FRAME: int = 8
const CAPACITY: int = 256
const LIFETIME_S: float = 3.0
## Under this air density (kg/m³) nothing flies: a storm's grains are not met in orbit.
const MIN_AIR_KG_M3: float = 0.05
## The ground cache's cell (m) and size.
const GROUND_CELL_M: float = 2.0
const GROUND_CACHE_MAX: int = 2048
## Sheltered (half a shelter or more), the ground populations are born at least this far (m) from the
## camera along the ground: past the walls of a room or a cab.
const SHELTER_CLEAR_M: float = 12.0

var _actor: Node3D = null
var _dust: SurfaceDust = null
## The populations and the look, read live (WeatherDust, from the weather effects scene).
var _cfg: WeatherDust = null
var _clouds: DustEmitter = null
var _streaks: DustEmitter = null
var _wisps: DustEmitter = null
var _age: float = INF  # since the last weather reading: INF = read now
var _rate: float = 0.0  # the clouds' strength, 0..1
var _lifted: float = 0.0  # the ground's lift, 0..1 (the streaks and wisps)
var _wind: Vector3 = Vector3.ZERO
var _owed: Array[float] = [0.0, 0.0, 0.0]  # puffs owed per population, fractional
## Ground radius (m from the planet's centre) per GROUND_CELL_M cell of the planet's frame: the exact
## ground (relief + canyons) is the dearest query on a client; a cell is asked once, the cache is
## dropped when it grows past GROUND_CACHE_MAX (the player has moved on).
var _ground_cache: Dictionary = {}
## The dust probe (client.ini debug_dust_probe=true): every PROBE_S, why the wind's dust is or is not
## drawn — the reading (height, air, wind, lift, ground family and its dustiness) and, per population,
## its rate and what its emitter did with the puffs (DustEmitter.probe_counts).
const PROBE_S: float = 2.0
var _probe_on: bool = ClientConfig.get_bool("debug_dust_probe", false)
var _probe_age: float = 0.0
var _probe_why: String = "not read yet"
var _probe_family: StringName = &""


## [param config] is the WeatherDust node of the weather effects scene (null = the code's defaults).
func _init(actor: Node3D, dust: SurfaceDust, config: WeatherDust = null) -> void:
	_actor = actor
	_dust = dust
	_cfg = config if config != null else WeatherDust.new()
	if dust != null:
		_clouds = DustEmitter.new(actor, dust)
		_streaks = DustEmitter.new(actor, dust)
		_wisps = DustEmitter.new(actor, dust)
		_tune()


## Once a frame on the client. [param family] is the ground under the actor (the footsteps' probe);
## [param shelter] (0 open, 1 walled in: ShelterProbe) stops the clouds past the visor, and pushes the
## births of the ground populations out beyond SHELTER_CLEAR_M: what blows outside is still seen
## through a window or a door, nothing is born in the room.
func update(delta: float, family: StringName, shelter: float = 0.0) -> void:
	_probe_family = family
	if _probe_on:
		_probe_age += delta
		if _probe_age >= PROBE_S:
			_probe_age = 0.0
			if _clouds == null or not DustEmitter.enabled() or WeatherBench.no_particles:
				_probe_why = "no emitters (%s), drawing enabled %s, bench no_particles %s" % [
					_clouds == null, DustEmitter.enabled(), WeatherBench.no_particles]
			_print_probe()
	if _clouds == null or not DustEmitter.enabled() or not is_instance_valid(_actor) \
			or not _actor.is_inside_tree() or WeatherBench.no_particles:
		return
	_age += delta
	if _age >= SAMPLE_S:
		_age = 0.0
		_cfg.fill_defaults()
		_tune()
		_resample()
	var exposed: float = 1.0 - clampf(shelter, 0.0, 1.0)
	var clear_m: float = SHELTER_CLEAR_M if shelter >= 0.5 else 0.0
	if _rate <= 0.0 and _lifted <= 0.0:
		_owed = [0.0, 0.0, 0.0, 0.0]
		return
	var camera: Camera3D = _actor.get_viewport().get_camera_3d()
	if camera == null:
		return
	var planet: Planet = Planet.of(_actor)
	# Up is the planet's radial where there is one (a stage rig does not stand upright), else the body's.
	var up: Vector3 = (_actor.global_position - planet.global_position).normalized() if planet != null \
			else _actor.global_basis.y.normalized()
	var eye: Vector3 = camera.global_position
	var c: DustPopulation = _cfg.clouds
	_owed[0] += c.rate_full * _rate * delta * exposed
	for _i in _take(_owed[0]):
		_owed[0] -= 1.0
		_clouds.puff(birth_point(eye, _wind, up, _jitter(), c.upwind_m, c.spread_m, c.height_m), family,
				c.opacity, _wind * c.speed_share + up * c.rise_ms, c.grains, c.patch_m, c.size_m)
	if _lifted <= 0.0 or planet == null:
		return
	var pops: Array = [[_cfg.streaks, _streaks, 1], [_cfg.wisps, _wisps, 2]]
	for entry: Array in pops:
		var p: DustPopulation = entry[0]
		var emitter: DustEmitter = entry[1]
		var k: int = entry[2]
		_owed[k] += p.rate_full * _lifted * delta
		for _i in _take(_owed[k]):
			_owed[k] -= 1.0
			# All around the camera (biased upwind by upwind_m), past the walls when sheltered.
			var at: Vector3 = beyond(birth_point(eye, _wind, up, _jitter(), p.upwind_m, p.spread_m, 0.0),
					eye, up, clear_m)
			emitter.puff(_on_ground_cached(planet, at, up, p.height_m * randf_range(0.2, 1.2)), family, p.opacity,
					_wind * p.speed_share + up * p.rise_ms * randf_range(0.5, 1.2), p.grains, p.patch_m, p.size_m)


## Push the populations' shape and the look into their emitters (live: read every refresh).
func _tune() -> void:
	var look: Dictionary = _cfg.look()
	for pair: Array in [[_cfg.clouds, _clouds], [_cfg.streaks, _streaks], [_cfg.wisps, _wisps]]:
		var p: DustPopulation = pair[0]
		var e: DustEmitter = pair[1]
		if p == null or e == null:
			continue
		e.set_shape(p.capacity, p.lifetime_s)
		e.set_stretch(p.stretch_per_ms)
		e.set_look(look)


## Free the clouds. Called by the owner when the body goes.
func release() -> void:
	for e: DustEmitter in [_clouds, _streaks, _wisps]:
		if e != null:
			e.release()


## Puffs per second for a dust optical depth [param dust_tau]: none under TAU_MIN, RATE_FULL from
## TAU_FULL, straight between.
static func rate_for(dust_tau: float) -> float:
	if dust_tau < TAU_MIN:
		return 0.0
	return RATE_FULL * clampf((dust_tau - TAU_MIN) / (TAU_FULL - TAU_MIN), 0.0, 1.0)


## How much of its ground a wind of [param wind_ms] lifts, 0..1, for a ground whose grains start to
## move at [param threshold_ms] (ClimateProfile.v10_threshold_m_s): Owen's saltation flux,
## ∝ v³ (1 - v_t²/v²) over the threshold, averaged over the gusts (the instant wind spread around its
## mean by GUST_INTENSITY), scaled to 1 at twice the threshold and capped there. A steady wind is never
## steady: the sand starts to stream in the gusts from about two thirds of the threshold and thickens
## as the mean climbs to it (a mean wind 1 km/h under the threshold lifted nothing at all, and over it
## the dust switched on, 2026-10-09). The plains blow sand at any good wind; a storm only blows more.
static func saltation_rate(wind_ms: float, threshold_ms: float) -> float:
	if threshold_ms <= 0.0 or wind_ms <= 0.0:
		return 0.0
	var sigma: float = GUST_INTENSITY * wind_ms
	var sum: float = 0.0
	var weights: float = 0.0
	for i in GUST_TAPS:
		var z: float = GUST_SPAN_SIGMA * (2.0 * (float(i) + 0.5) / float(GUST_TAPS) - 1.0)
		var w: float = exp(-0.5 * z * z)
		sum += w * owen_flux(wind_ms + sigma * z, threshold_ms)
		weights += w
	return clampf(sum / weights, 0.0, 1.0)


## The settled film's share for a wind of [param wind_ms]: from the first breeze, saturating at FILM_MAX.
static func film_rate(wind_ms: float) -> float:
	if wind_ms <= 0.0:
		return 0.0
	return FILM_MAX * (1.0 - exp(-wind_ms / FILM_SCALE_MS))


## What the wind lifts off the ground, 0..1: the settled film from the first breeze, plus the sand's
## saltation over its threshold (saltation_rate). The one number the streaks, the wisps, the near
## dust layer and the dev panel all read.
static func ground_lift(wind_ms: float, threshold_ms: float) -> float:
	return clampf(film_rate(wind_ms) + saltation_rate(wind_ms, threshold_ms), 0.0, 1.0)


## Owen's flux for an instant wind [param v_ms] over a threshold [param threshold_ms], in units of its
## value at twice the threshold (uncapped: the gusts' average is capped once, after).
static func owen_flux(v_ms: float, threshold_ms: float) -> float:
	if v_ms <= threshold_ms:
		return 0.0
	return (v_ms * v_ms * v_ms - threshold_ms * threshold_ms * v_ms) / (6.0 * threshold_ms * threshold_ms * threshold_ms)


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


## [param point] pushed out along the ground, away from [param eye], to at least [param min_m] from it:
## the births kept outside the room a sheltered player stands in. 0 = untouched.
static func beyond(point: Vector3, eye: Vector3, up: Vector3, min_m: float) -> Vector3:
	if min_m <= 0.0:
		return point
	var n: Vector3 = up.normalized() if not up.is_zero_approx() else Vector3.UP
	var flat: Vector3 = point - eye
	flat -= n * flat.dot(n)
	var d: float = flat.length()
	if d >= min_m:
		return point
	var dir: Vector3 = flat / d if d > 1e-3 else n.cross(Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.FORWARD).normalized()
	return point + dir * (min_m - d)


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


## on_the_ground with the ground radius cached per cell (see _ground_cache).
func _on_ground_cached(planet: Planet, near: Vector3, up: Vector3, height_m: float) -> Vector3:
	if planet == null or planet.planet_data == null:
		return near + up * height_m
	var dir: Vector3 = planet.local_dir_of(near)
	if dir.is_zero_approx():
		return near + up * height_m
	var cell_v: Vector3 = dir * planet.planet_data.radius / GROUND_CELL_M
	var cell := Vector3i(roundi(cell_v.x), roundi(cell_v.y), roundi(cell_v.z))
	var ground: float
	if _ground_cache.has(cell):
		ground = _ground_cache[cell]
	else:
		if _ground_cache.size() >= GROUND_CACHE_MAX:
			_ground_cache.clear()
		ground = planet.planet_data.crack_aware_surface_dist(dir)
		_ground_cache[cell] = ground
	return planet.to_global(dir * (ground + height_m))


static func _jitter() -> Vector3:
	return Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))


func _print_probe() -> void:
	var line: String = "[DustProbe] GROUND %s | wind %.1f m/s lift %.1f%% clouds %.1f%% | ground %s dustiness %.2f" % [
		_probe_why, _wind.length(), _lifted * 100.0, _rate * 100.0, _probe_family,
		_dust.amount(_probe_family) if _dust != null else -1.0]
	for entry: Array in [["clouds", _cfg.clouds, _clouds], ["streaks", _cfg.streaks, _streaks],
			["wisps", _cfg.wisps, _wisps]]:
		var p: DustPopulation = entry[1]
		var e: DustEmitter = entry[2]
		if p == null or e == null:
			line += " | %s: none" % entry[0]
			continue
		var c: Dictionary = e.probe_counts
		line += " | %s: %.0f/s full, opacity %.2f -> drawn %d (%d grains) faint %d far %d no frame %d" % [
			entry[0], p.rate_full, p.opacity, c["drawn"], c["grains"], c["faint"], c["far"], c["no_frame"]]
		e.probe_counts = {"drawn": 0, "faint": 0, "far": 0, "no_frame": 0, "grains": 0}
	print(line)


## How high [param pos] (world) stands over [param planet]'s real ground (m), relief and canyons included.
static func height_over_ground(planet: Planet, pos: Vector3) -> float:
	var dir: Vector3 = planet.local_dir_of(pos)
	if dir.is_zero_approx():
		return 0.0
	return planet.global_position.distance_to(pos) - planet.planet_data.crack_aware_surface_dist(dir)


## How many puffs an owed count pays for this frame, capped.
static func _take(owed: float) -> int:
	return clampi(int(owed), 0, MAX_PUFFS_PER_FRAME)


func _resample() -> void:
	_rate = 0.0
	_lifted = 0.0
	_wind = Vector3.ZERO
	var planet: Planet = Planet.of(_actor)
	if planet == null or planet.planet_data == null:
		_probe_why = "no planet"
		return
	# The wind lifts the GROUND, whatever the eye does: floating (god mode, a jetpack) a few metres over
	# it still sees the sand stream. Only the height cuts it off; in space the thin air below does.
	var height: float = height_over_ground(planet, _actor.global_position)
	if height > VIEW_HEIGHT_MAX_M:
		_probe_why = "%.0f m over the ground (> %.0f m)" % [height, VIEW_HEIGHT_MAX_M]
		return
	var sample: Dictionary = planet.weather_at(_actor.global_position)
	if sample.is_empty():
		_probe_why = "no weather sample"
		return
	var air: float = float(sample.get("air_density_kg_m3", 0.0))
	if air < MIN_AIR_KG_M3:
		_probe_why = "air %.3f kg/m3 (< %.2f)" % [air, MIN_AIR_KG_M3]
		return
	_probe_why = "height %.1f m, air %.3f kg/m3, regional dust tau %.2f, sample wind %.1f m/s" % [height, air,
			float(sample.get("dust_tau", 0.0)), float(sample.get("wind_speed_m_s", 0.0))]
	_rate = rate_for(float(sample.get("dust_tau", 0.0))) / RATE_FULL
	_wind = planet.wind_world_at(_actor.global_position)
	var profile: ClimateProfile = planet.climate_profile()
	_lifted = ground_lift(_wind.length(), profile.v10_threshold_m_s if profile != null else 0.0)
