class_name DustLift
extends RefCounted
## How much of its ground a wind lifts, 0..1: the one number the wind's dust is drawn from (the dust
## layer near the ground, WeatherSky). Pure maths, no scene: the weather says the wind and the ground's
## threshold (WeatherSource "lift_threshold_m_s"), this says the dust.

## The turbulence intensity of the wind near the ground (the spread of the instant wind around its
## mean, as a share of it: 0.2 over open flats, 0.3 over rough ground). The gusts over the threshold
## lift sand while the mean wind is still under it.
const GUST_INTENSITY: float = 0.25
## The gusts' spread is integrated over this many standard deviations each side, in GUST_TAPS taps.
const GUST_SPAN_SIGMA: float = 3.5
const GUST_TAPS: int = 29
## The film of fine dust settled on every ground, rock included (nothing binds it): the first breeze
## lifts some of it, more as the wind grows, up to FILM_MAX of a full blow with FILM_SCALE_MS the wind
## that lifts 63 % of that. Under the sand's threshold it is all there is: with the threshold alone a
## rock plain at 25 km/h stayed dead still (2026-10-09).
const FILM_MAX: float = 0.08
const FILM_SCALE_MS: float = 6.0


## What a wind of [param wind_ms] lifts off a ground whose grains start to move at [param threshold_ms],
## 0..1: the settled film from the first breeze, plus the sand's saltation over its threshold.
static func ground_lift(wind_ms: float, threshold_ms: float) -> float:
	return clampf(film_rate(wind_ms) + saltation_rate(wind_ms, threshold_ms), 0.0, 1.0)


## How much of its ground a wind of [param wind_ms] lifts by saltation, 0..1: Owen's flux,
## ∝ v³ (1 - v_t²/v²) over the threshold, averaged over the gusts (the instant wind spread around its
## mean by GUST_INTENSITY), 1 at twice the threshold and capped there. A steady wind is never steady:
## the sand starts to stream in the gusts from about two thirds of the threshold and thickens as the
## mean climbs to it (a mean wind 1 km/h under the threshold lifted nothing at all, and over it the
## dust switched on, 2026-10-09).
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


## Owen's flux for an instant wind [param v_ms] over a threshold [param threshold_ms], in units of its
## value at twice the threshold (uncapped: the gusts' average is capped once, after).
static func owen_flux(v_ms: float, threshold_ms: float) -> float:
	if v_ms <= threshold_ms:
		return 0.0
	return (v_ms * v_ms * v_ms - threshold_ms * threshold_ms * v_ms) / (6.0 * threshold_ms * threshold_ms * threshold_ms)
