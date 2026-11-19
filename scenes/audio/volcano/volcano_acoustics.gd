class_name VolcanoAcoustics
extends RefCounted
## What the distance does to the sound of a volcano: the delay of its travel, how much is left of it,
## how muffled and how reverberated it arrives. Pure functions, in metres and seconds.
##
## Godot's attenuation models are written for a street, not for 40 km: VolcanoSound disables them and
## asks these curves instead.

## Silence, in dB.
const SILENT_DB: float = -80.0
## The low-pass is transparent up there (Hz).
const OPEN_CUTOFF_HZ: float = 20000.0
## Share of a sound's range over which it slides to silence, so the edge of the range is no switch.
const EDGE_SHARE: float = 0.1


## Seconds a sound takes to travel [param distance_m] at [param speed_m_s].
static func delay_s(distance_m: float, speed_m_s: float) -> float:
	return maxf(distance_m, 0.0) / maxf(speed_m_s, 1.0)


## The moment of the volcano's life heard NOW from [param distance_m] away: the clock, less the travel.
## Every sound reads the eruption schedule at this time instead of the clock's.
static func heard_time(now: float, distance_m: float, speed_m_s: float) -> float:
	return now - delay_s(distance_m, speed_m_s)


## 0 near the source .. 1 at [param far_m], along the logarithm of the distance (the ear's own scale).
static func farness(distance_m: float, near_m: float, far_m: float) -> float:
	if far_m <= near_m or distance_m <= near_m:
		return 0.0
	return clampf(log(distance_m / near_m) / log(far_m / near_m), 0.0, 1.0)


## What the distance takes off a sound (dB, <= 0): nothing up to [param full_m], then straight down in
## decibels to [param far_db] at [param max_m], silence beyond. The last EDGE_SHARE of the range slides
## to silence.
static func gain_db(distance_m: float, full_m: float, max_m: float, far_db: float) -> float:
	if distance_m >= max_m:
		return SILENT_DB
	var db: float = far_db * farness(distance_m, full_m, max_m)
	return lerpf(db, SILENT_DB, smoothstep(1.0 - EDGE_SHARE, 1.0, distance_m / max_m))


## The low-pass cut-off (Hz) at [param distance_m]: the air takes the highs first. Open up to
## [param near_m], [param far_hz] from [param far_m], in octaves between.
static func cutoff_hz(distance_m: float, near_m: float, far_m: float, far_hz: float) -> float:
	return exp(lerpf(log(OPEN_CUTOFF_HZ), log(far_hz), farness(distance_m, near_m, far_m)))


## The share (0..1) of reverberated sound at [param distance_m]: from [param near_wet] to
## [param far_wet], the roll of a far thunder.
static func reverb_wet(distance_m: float, near_m: float, far_m: float, near_wet: float, far_wet: float) -> float:
	return lerpf(near_wet, far_wet, farness(distance_m, near_m, far_m))
