class_name WeatherForces
extends RefCounted
## What the wind DOES to a body — the server's side of the weather (the forces are the server's, the
## clients only show). Pure functions of the air and the body, so the numbers can be checked without
## a scene: a flat-plate drag, ½ρ·C·A·|v|·v, where v is the air's motion RELATIVE to the body (the
## wind minus the body's own velocity), ρ the air's density where the body is
## (AtmosphereProfile.air_density), C and A the body's drag coefficient and the area it shows.
##
## Simplifications, named: no shelter (a canyon wall, a building, a truck's lee cut nothing yet);
## the coefficient and the area constant whatever the angle; on foot, the feet HOLD up to a static
## friction (HOLD_FRICTION of the weight: a breeze slides nobody) and past it the body slips at a
## speed proportional to the excess (a viscous coupling with the ground), not a balance of torques;
## no gust beyond the sampler's (none yet).
##
## Switched by server.ini: [weather] forces=0 turns every push off (the weather is still drawn).

## The dedicated server reads the switch once; the clients never push anything.
static var enabled: bool = SettingsManager._server_ini_number("weather", "forces", 1.0) > 0.5
## A body refreshes its wind every so many physics frames (10 Hz at 60 Hz): the wind changes over
## minutes, the sampler costs tens of microseconds per call, and there are many bodies.
const REFRESH_EVERY_FRAMES: int = 6
## A person on foot: a flat plate of 0.6 m² (standing, square to the wind), C 1.0.
const PLAYER_DRAG: float = 1.0
const PLAYER_AREA_M2: float = 0.6
## On foot, the slip speed the push buys past what the feet hold: (F - hold)/m × DRIFT_RESPONSE_S,
## capped at DRIFT_CAP_MS. An 80 kg body on Tarsis III: 30 m/s (341 N) slips 0.4 m/s, 45 m/s (768 N)
## 5.8 m/s backwards; the cap keeps a 60 m/s gale from throwing anyone across the map.
const DRIFT_RESPONSE_S: float = 1.0
const DRIFT_CAP_MS: float = 8.0
## What the feet hold before they slip, as a share of the weight (a static friction coefficient):
## 0.4 × 80 kg × 9.6 m/s² = 307 N on Tarsis III, the push of a 28 m/s wind on a standing body. Under
## it the wind is seen and heard, not felt in the legs; a storm moves you.
const HOLD_FRICTION: float = 0.4
## In the air (a jump, a fall) the push accelerates the body freely, capped to a sane figure.
const ACCEL_CAP_MS2: float = 15.0


## The drag force (N) of air of density [param air_density] (kg/m³) moving at [param relative_wind]
## (m/s, the wind minus the body's velocity) on a body of drag coefficient [param drag_coefficient]
## showing [param area_m2]: ½ρ·C·A·|v|·v, along the relative wind.
static func drag_force(air_density: float, drag_coefficient: float, area_m2: float,
		relative_wind: Vector3) -> Vector3:
	var speed: float = relative_wind.length()
	if speed <= 0.0 or air_density <= 0.0:
		return Vector3.ZERO
	return 0.5 * air_density * drag_coefficient * area_m2 * speed * relative_wind


## The wind's OWN contribution to the drag of a body moving at [param velocity] in a wind
## [param wind] (both m/s, one frame): the drag in the moving air minus the drag in still air, which
## the body's own model already applies. Still air gives zero at any speed; a body at rest gets the
## full push ½ρ·C·A·|w|·w; a headwind adds drag, a tailwind takes some away.
static func wind_push(air_density: float, drag_coefficient: float, area_m2: float, velocity: Vector3,
		wind: Vector3) -> Vector3:
	if wind.is_zero_approx():
		return Vector3.ZERO
	return drag_force(air_density, drag_coefficient, area_m2, wind - velocity) \
			- drag_force(air_density, drag_coefficient, area_m2, -velocity)


## The push as an acceleration (m/s²) on a body of [param mass_kg], capped at [param cap].
static func acceleration(force: Vector3, mass_kg: float, cap: float = ACCEL_CAP_MS2) -> Vector3:
	if mass_kg <= 0.0:
		return Vector3.ZERO
	return (force / mass_kg).limit_length(cap)


## On foot: the ground speed (m/s) the wind costs a body of [param mass_kg] whose feet hold
## [param hold_n] of push — the excess over it as an acceleration over DRIFT_RESPONSE_S, capped at
## DRIFT_CAP_MS; nothing under the hold.
static func drift_velocity(force: Vector3, mass_kg: float, hold_n: float = 0.0) -> Vector3:
	if mass_kg <= 0.0:
		return Vector3.ZERO
	var push: float = force.length()
	if push <= 0.0 or push <= hold_n:
		return Vector3.ZERO
	return (force / push * ((push - hold_n) / mass_kg * DRIFT_RESPONSE_S)).limit_length(DRIFT_CAP_MS)


## The push (N) the feet of a body of [param mass_kg] hold under [param gravity] (m/s²) before they
## slip: HOLD_FRICTION of its weight.
static func hold_force(mass_kg: float, gravity: float) -> float:
	return HOLD_FRICTION * maxf(mass_kg, 0.0) * maxf(gravity, 0.0)


## The part of [param wind] along the ground, for a body standing on it: the wind minus its
## component along [param up] (an updraft lifts nobody).
static func along_ground(wind: Vector3, up: Vector3) -> Vector3:
	if up.is_zero_approx():
		return wind
	var n: Vector3 = up.normalized()
	return wind - n * wind.dot(n)


## The air's density (kg/m³) where [param world_pos] stands on [param planet]; 0 without air.
static func air_density_at(planet: Planet, world_pos: Vector3) -> float:
	if planet == null or planet.planet_data == null or planet.planet_data.atmosphere_profile == null:
		return 0.0
	return planet.planet_data.atmosphere_profile.air_density(planet.elevation_of(world_pos))
