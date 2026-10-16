class_name VehicleTyreSound
extends RefCounted

## How the tyres' rolling noise follows the speed: louder and higher the faster they go.
##
## Kept out of vehicle.gd for the same reason as the dust and the odometer: that file is at gdlint's
## public-method ceiling, and this is a rule of its own.
##
## The physics: the noise of a tyre on the ground grows with the LOGARITHM of the speed -- every
## doubling adds the same few decibels, it does not double the loudness -- and its pitch rises with the
## speed, because the tread blocks strike the ground more often per second. Both settle at a top speed,
## past which a looped sample stretched any further stops sounding like a tyre.


## Decibels (0 or below) to add to the roll's level at [param speed_kmh]: 0 at [param top_kmh], minus
## [param db_per_doubling] for each halving of the speed below it, down to [param low_kmh] (where the
## loop has faded in from standstill). Static and pure: tested without a vehicle.
static func roll_db(speed_kmh: float, low_kmh: float, top_kmh: float, db_per_doubling: float) -> float:
	var top: float = maxf(top_kmh, 0.1)
	var speed: float = clampf(absf(speed_kmh), minf(maxf(low_kmh, 0.1), top), top)
	return -maxf(db_per_doubling, 0.0) * log(top / speed) / log(2.0)


## Playback speed of the roll at [param speed_kmh]: [param low_pitch] up to [param low_kmh], rising in
## step with the speed to [param high_pitch] at [param top_kmh], held past it. Static and pure.
static func roll_pitch(speed_kmh: float, low_kmh: float, top_kmh: float, low_pitch: float,
		high_pitch: float) -> float:
	var t: float = clampf((absf(speed_kmh) - low_kmh) / maxf(top_kmh - low_kmh, 0.1), 0.0, 1.0)
	return maxf(lerpf(low_pitch, high_pitch, t), 0.01)
