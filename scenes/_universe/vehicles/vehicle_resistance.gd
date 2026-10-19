class_name VehicleResistance
extends RefCounted

## What holds a vehicle back while it moves: the air it pushes through, and the tyres rolling on the
## ground. VehicleBody3D models neither, so without them a truck at full throttle needed no push at all
## to keep its speed, and its batteries stopped draining at top speed (playtest 2026-10-19). With them,
## the motors push -- and draw -- whatever the speed takes to hold.
##
## The air is the planet's (Vehicle.air_density_now: its atmosphere at the vehicle's altitude), so a
## truck runs freer up on the plateau and meets no air at all on an airless world. Both forces oppose
## the motion. Static and pure: tested without a vehicle.

## Below this speed (m/s) the rolling resistance fades out instead of pushing back and forth across zero
## on a vehicle at rest.
const ROLLING_FADE_MS: float = 0.5


## Aerodynamic drag (N) at [param speed_ms]: ½·ρ·Cd·A·v².
static func aero_n(speed_ms: float, air_density: float, drag_coefficient: float, frontal_area_m2: float) -> float:
	return 0.5 * maxf(air_density, 0.0) * maxf(drag_coefficient, 0.0) * maxf(frontal_area_m2, 0.0) * speed_ms * speed_ms


## Rolling resistance (N) of [param mass_kg] on its tyres: Crr·m·g, faded in over ROLLING_FADE_MS.
static func rolling_n(speed_ms: float, mass_kg: float, gravity: float, coefficient: float) -> float:
	var fade: float = clampf(absf(speed_ms) / ROLLING_FADE_MS, 0.0, 1.0)
	return maxf(coefficient, 0.0) * maxf(mass_kg, 0.0) * maxf(gravity, 0.0) * fade


## The force (N, a vector) holding back a body moving at [param velocity]: the air against the whole
## motion, the tyres only while [param grounded].
static func force(velocity: Vector3, air_density: float, drag_coefficient: float, frontal_area_m2: float,
		mass_kg: float, gravity: float, rolling_coefficient: float, grounded: bool) -> Vector3:
	var speed: float = velocity.length()
	if speed < 0.001:
		return Vector3.ZERO
	var magnitude: float = aero_n(speed, air_density, drag_coefficient, frontal_area_m2)
	if grounded:
		magnitude += rolling_n(speed, mass_kg, gravity, rolling_coefficient)
	return -velocity / speed * magnitude
