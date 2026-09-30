class_name StageClock
extends RefCounted
## The hour of day on the stage. With the clock frozen (StageSession: time_scale 0, so sim_time() IS
## Globals.debug_time_offset), setting an hour means finding the simulation time at which the planet
## shows the star that hour at the anchor — and placing the planet there.
##
## Solved by asking the planet itself (Planet.get_local_solar_time, the game's own sundial) rather
## than re-deriving the geometry: a few corrections of the offset converge, because the orbit moves
## a fraction of a degree a day while the spin sweeps the whole 24 h.

const _ITERATIONS : int = 5


## 17.25 -> "17:15".
static func format(hours: float) -> String:
	var minutes : int = roundi(fposmod(hours, 24.0) * 60.0)
	@warning_ignore("integer_division")
	return "%02d:%02d" % [(minutes / 60) % 24, minutes % 60]


## Put `planet` at `hour` (0..24) for the planet-local point `anchor_local`. Returns the hour reached.
static func set_hour(planet: Planet, anchor_local: Vector3, hour: float) -> float:
	var day_s : float = planet.rotation_period_hours * 3600.0
	if day_s <= 0.0:
		return -1.0
	var reached : float = -1.0
	for i in _ITERATIONS:
		planet.place_now()
		reached = planet.get_local_solar_time(planet.to_global(anchor_local))
		if reached < 0.0:
			return reached  # no star, or the anchor on a pole: no hour to reach
		var miss : float = wrapf(hour - reached, -12.0, 12.0)
		if absf(miss) < 0.01:
			break
		Globals.debug_time_offset += miss / 24.0 * day_s
	planet.place_now()
	return reached


## The sun's height above the horizon at the anchor, in degrees (negative: below it).
static func sun_elevation(planet: Planet, anchor_local: Vector3) -> float:
	var star : Node3D = planet.star()
	if star == null:
		return -90.0
	var here : Vector3 = planet.to_global(anchor_local)
	var up : Vector3 = (here - planet.global_position).normalized()
	return rad_to_deg(asin(clampf(up.dot((star.global_position - here).normalized()), -1.0, 1.0)))


## Put the sun `elevation_deg` above the horizon, in the morning (sunrise side) or the evening — a
## look that holds whatever the season, where a fixed hour can land in the dark. Found by bisection
## on the hour between midnight and noon (or noon and midnight); returns the hour set, -1 when the
## sun never gets that high (polar night) and the planet is left at noon.
static func set_sun_elevation(planet: Planet, anchor_local: Vector3, elevation_deg: float,
		morning: bool = true) -> float:
	var low : float = 0.0 if morning else 12.0
	var high : float = 12.0 if morning else 24.0
	set_hour(planet, anchor_local, 12.0)
	if sun_elevation(planet, anchor_local) < elevation_deg:
		return -1.0
	for i in 16:
		var mid : float = (low + high) / 2.0
		set_hour(planet, anchor_local, mid)
		# Morning: the sun climbs with the hour; evening: it sinks.
		if (sun_elevation(planet, anchor_local) < elevation_deg) == morning:
			low = mid
		else:
			high = mid
	var hour : float = (low + high) / 2.0
	set_hour(planet, anchor_local, hour)
	return hour
