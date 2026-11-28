class_name VillageAlarm
extends RefCounted
## A village's storm alarm: the siren on its mast that warns of a dust wall or a dust storm coming, sounds
## while it is there, and stops once it has gone. The game SERVER decides it for each village it holds
## (poi_villages.gd), from the same deterministic weather every machine computes; the state travels as the
## village's "alarm" / "alarm_since" properties and each client only plays what it receives (VillageSiren).
##
## - WARNING: an arrival is expected within LOOKAHEAD_S: the siren sounds once every WARNING_PERIOD_S.
## - DURING: the danger is at the village: the siren loops.
## - OFF: nothing in sight. The alarm climbs at once and comes down only once the lower state has held for
##   CLEAR_HOLD_S (hysteresis), so a forecast hovering on a threshold does not flicker the siren.
##
## Danger: a wall's dust at the village centre over WALL_DANGER_TAU (WeatherRelief.wall_effect), or the
## storms' dust there over STORM_DANGER_TAU (the dust of the service's systems, WeatherSampler.air).
## The forecast samples LOOKAHEAD_S every STEP_S: a wall's dust stays over WALL_DANGER_TAU for about 2.5 of its
## depths behind the front (its tail, WeatherRelief.WALL_TAIL_FALL), so over 3.5 km, and it runs at most
## WALL_SPEED_MAX_M_S, so a step of 30 s never steps over it.
##
## The same dust, now, also dims the village's daylight (dust_tau_at, dust_light): the server replicates the
## share it leaves as the village's "dust_light", and the street lamps' photocells multiply it into the
## daylight they read (Planet.daylight_through_weather_at), so they come on in a dark enough storm.
##
## Two clocks: the weather is forecast on the shared simulation clock (ClimateWeather.now()); the alarm's own
## timings (hold, drill, the siren's rhythm) are human-paced, on Globals.reference_time(), which every machine
## agrees on whatever the pace the sky is shown at.

const OFF := &"off"
const WARNING := &"warning"
const DURING := &"during"

## How far ahead an arrival raises the warning, seconds of simulation time.
const LOOKAHEAD_S := 600.0
## The forecast's step, seconds of simulation time.
const STEP_S := 30.0
## How long a lower state must hold before the alarm comes down to it, seconds.
const CLEAR_HOLD_S := 60.0
## While warning, the siren sounds once at the start of each period, seconds.
const WARNING_PERIOD_S := 60.0
## A wall's dust optical depth at the village centre that counts as there (WALL_TAU is 8 behind a whole
## front; 0.5 is about 8 km of visibility in the dust layer: a weak, dying wall does not wake the village).
const WALL_DANGER_TAU := 0.5
## The storms' dust that counts as a storm there: the dust from which a dust wall cannot fall any more
## (WeatherRelief.WALL_VEIL_TAU[0]), the air being a storm's already.
const STORM_DANGER_TAU := 1.5
## The admin drill (drill): its warning, then its siren, seconds.
const DRILL_WARNING_S := 30.0
const DRILL_DURING_S := 30.0
## The step the dust's share of the daylight over a village is replicated in (dust_light): a hundredth
## moves the photocells' reading by 1 %, finer than the gap between their two thresholds (63 %).
const DUST_LIGHT_STEP := 0.01

## The state now, and the reference time it began at (the siren's rhythm counts from it).
var state: StringName = OFF
var since: float = 0.0
var _lower_since: float = -1.0  # when a lower state was first wanted, -1 while none is
var _drill_from: float = -1.0  # when a drill began, -1 without one


## The state an arrival in [param eta_s] seconds calls for (-1: none in sight, 0: there now).
static func wanted_for(eta_s: float) -> StringName:
	if eta_s < 0.0:
		return OFF
	if eta_s == 0.0:
		return DURING
	return WARNING if eta_s <= LOOKAHEAD_S else OFF


## The first offset (s) of 0, STEP_S, … up to [param lookahead_s] at which [param danger_at] (Callable(offset_s)
## -> bool) answers true, -1 when it never does.
static func eta(danger_at: Callable, lookahead_s: float = LOOKAHEAD_S, step_s: float = STEP_S) -> float:
	var offset := 0.0
	while offset <= lookahead_s:
		if bool(danger_at.call(offset)):
			return offset
		offset += step_s
	return -1.0


## True when one of [param walls] (WeatherRelief.walls_near's) lays dust of WALL_DANGER_TAU or more on
## [param at] (lon, lat in degrees).
static func wall_danger(walls: Array, at: Vector2, radius_m: float) -> bool:
	for wall: Dictionary in walls:
		if float(WeatherRelief.wall_effect(wall, at, radius_m)[1]) >= WALL_DANGER_TAU:
			return true
	return false


## True when the storms' [param dust_tau] makes a storm.
static func storm_danger(dust_tau: float) -> bool:
	return dust_tau >= STORM_DANGER_TAU


## Whether [param weather] holds danger at [param lonlat] of [param planet] at simulation time [param t]: a
## wall (ClimateWeather.walls_at, called-in walls included) or the storms walked there (systems_at). Main
## thread only (it reads the weather systems' nodes).
static func danger_at(weather: ClimateWeather, planet: Planet, lonlat: Vector2, t: float) -> bool:
	var r: float = weather.profile.radius_m
	if weather.local_enabled and planet.planet_data != null \
			and wall_danger(weather.walls_at(planet, lonlat, t), lonlat, r):
		return true
	var air := WeatherSampler.air(weather.profile, weather.systems_at(planet, t), lonlat.x, lonlat.y)
	return storm_danger(float(air["dust_tau"]))


## The storm's dust optical depth over [param lonlat] of [param planet] at simulation time [param t]: the
## walls' (summed as WeatherRelief.apply sums them) and the storms' (the systems' dust), the two dangers
## danger_at weighs one by one. Main thread only (it reads the weather systems' nodes).
static func dust_tau_at(weather: ClimateWeather, planet: Planet, lonlat: Vector2, t: float) -> float:
	var tau := 0.0
	if weather.local_enabled and planet.planet_data != null:
		tau = walls_tau(weather.walls_at(planet, lonlat, t), lonlat, weather.profile.radius_m)
	var air := WeatherSampler.air(weather.profile, weather.systems_at(planet, t), lonlat.x, lonlat.y)
	return tau + maxf(float(air["dust_tau"]), 0.0)


## The dust optical depth [param walls] (WeatherRelief.walls_near's) lay on [param at] (lon, lat in degrees).
static func walls_tau(walls: Array, at: Vector2, radius_m: float) -> float:
	var tau := 0.0
	for wall: Dictionary in walls:
		tau += float(WeatherRelief.wall_effect(wall, at, radius_m)[1])
	return tau


## The share of the daylight a storm's dust of optical depth [param tau] leaves on flat ground (0..1): the
## two-stream total of that dust, absorbing as a storm's does (DustLight.total, STORM_ALBEDO), the direct
## beam's Beer share included. Rounded to DUST_LIGHT_STEP: the server replicates it only when it changes.
static func dust_light(tau: float) -> float:
	return snappedf(DustLight.total(maxf(tau, 0.0), DustLight.STORM_ALBEDO), DUST_LIGHT_STEP)


## The rank of a state: OFF < WARNING < DURING.
static func rank(of: StringName) -> int:
	return [OFF, WARNING, DURING].find(of)


## Brings the alarm to reference time [param t], an arrival forecast in [param eta_s] (see wanted_for). True
## when the state changed (the server then replicates it).
func step(t: float, eta_s: float) -> bool:
	var wanted := wanted_for(eta_s)
	if _drill_from >= 0.0:
		var age := t - _drill_from
		if age < DRILL_WARNING_S + DRILL_DURING_S:
			return _enter(WARNING if age < DRILL_WARNING_S else DURING, t)
		# The drill is over: straight to what the weather calls for, no hold (the drill was not weather).
		_drill_from = -1.0
		_lower_since = -1.0
		return _enter(wanted, t)
	if rank(wanted) >= rank(state):
		_lower_since = -1.0
		return _enter(wanted, t)
	if _lower_since < 0.0:
		_lower_since = t
	if t - _lower_since < CLEAR_HOLD_S:
		return false
	_lower_since = -1.0
	return _enter(wanted, t)


## Starts the admin drill at reference time [param t]: DRILL_WARNING_S of warning, DRILL_DURING_S of siren,
## then whatever the weather calls for. The caller steps the alarm at once and at each phase's end.
func drill(t: float) -> void:
	_drill_from = t


func _enter(to: StringName, t: float) -> bool:
	if to == state:
		return false
	state = to
	since = t
	return true


## Where the siren should be in its sample at reference time [param t] for [param of] begun at
## [param from_t], seconds into a sample [param length_s] long; -1 for silence. DURING: the loop, in step on
## every machine. WARNING: one sounding at the start of each WARNING_PERIOD_S, played from the head of the
## sound (the sample starts at the bottom of the wail and ends there). A client joining mid-way picks the
## siren up where the others hear it, rather than waiting for the next sounding.
static func siren_position(of: StringName, from_t: float, t: float, length_s: float) -> float:
	if length_s <= 0.0:
		return -1.0
	var age := maxf(t - from_t, 0.0)
	if of == DURING:
		return fmod(age, length_s)
	if of == WARNING:
		var into := fmod(age, WARNING_PERIOD_S)
		return into if into < length_s else -1.0
	return -1.0
