class_name WeatherLocal
extends RefCounted
## The wind where you STAND, from the wind the synoptic sampler gives the region (WeatherSampler): the
## LOCAL layer of the model — the canyon's channelling and shelter, and the gusts. Pure functions of
## the sample, the ground (Planet.canyon_at) and the shared clock, the same on the server and on every
## client, so a truck is pushed by the gust its driver hears.
##
## Canyons (rapport 02 §1.3–1.4): a wind ALONG a trench is channelled and speeds up (×1.5 to ×3 at a
## gap's exit; CANYON_ALONG_GAIN inside the trench); a wind ACROSS a trench as deep as it is wide
## (Tarsis III: H/W = 180/250 = 0.72, Oke's skimming regime) rolls over it and the floor is sheltered
## (×0.3 to ×0.7: CANYON_ACROSS_FACTOR). Named simplifications: the network is a lattice of trenches
## around blocks, with no mouths, so the exit speed-up is not modelled; the night's drainage down the
## trenches needs a slope the network does not give — neither is in yet.
##
## Gusts (§1.5, Davenport): the wind breathes around its mean, peak over mean ≈ 1.35 over minutes.
## Modelled as the sum of four sinusoids (0.05 to 0.5 Hz) whose phases are hashed from the body's seed
## and a 2 km cell of the ground, blended between the four cells around the point so a walk never
## steps — no state anywhere: a client that joins computes the gust the server felt a minute ago.

## The gain of the wind along a trench on its floor, and what is left of the wind across it.
const CANYON_ALONG_GAIN: float = 1.8
const CANYON_ACROSS_FACTOR: float = 0.4
## The gust's swing around the mean: the peak factor is 1 + GUST_SWING.
const GUST_SWING: float = 0.35
## The sinusoids of a gust (Hz) and their shares (they sum to 1).
const GUST_HZ: Array[float] = [0.05, 0.13, 0.31, 0.5]
const GUST_WEIGHT: Array[float] = [0.5, 0.3, 0.15, 0.05]
## Side of a gust's cell on the ground, in degrees of longitude and latitude: ~2 km on Tarsis III.
const GUST_CELL_DEG: float = 0.02


## The wind (east, north) in a canyon: its part along [param axis] (a unit (east, north) along the
## trench) gains CANYON_ALONG_GAIN, its part across keeps CANYON_ACROSS_FACTOR, both faded by
## [param depth] (0 = the open plateau, 1 = the floor of the trench).
static func canyon_wind(east: float, north: float, axis: Vector2, depth: float) -> Vector2:
	var k: float = clampf(depth, 0.0, 1.0)
	var wind := Vector2(east, north)
	if k <= 0.0 or axis.is_zero_approx():
		return wind
	var a: Vector2 = axis.normalized()
	var along: float = wind.dot(a)
	var across: Vector2 = wind - a * along
	return a * along * lerpf(1.0, CANYON_ALONG_GAIN, k) + across * lerpf(1.0, CANYON_ACROSS_FACTOR, k)


## The gust factor (peak 1 + GUST_SWING, trough 1 - GUST_SWING) at (lon, lat) and time [param t] (s,
## the shared clock) on a body of [param seed]: the four cells around the point, each with its own
## hashed phases, blended with a smoothstep so the factor is continuous across the ground.
static func gust_factor(seed: int, lon_deg: float, lat_deg: float, t: float) -> float:
	var x: float = lon_deg / GUST_CELL_DEG
	var y: float = lat_deg / GUST_CELL_DEG
	var ix: int = floori(x)
	var iy: int = floori(y)
	var fx: float = x - float(ix)
	var fy: float = y - float(iy)
	var sx: float = fx * fx * (3.0 - 2.0 * fx)
	var sy: float = fy * fy * (3.0 - 2.0 * fy)
	var low: float = lerpf(_cell_swing(seed, ix, iy, t), _cell_swing(seed, ix + 1, iy, t), sx)
	var high: float = lerpf(_cell_swing(seed, ix, iy + 1, t), _cell_swing(seed, ix + 1, iy + 1, t), sx)
	return 1.0 + GUST_SWING * lerpf(low, high, sy)


## One cell's swing in [-1, 1] at time t: the sinusoids at their hashed phases (MountainNoise's integer
## hash, the one the canyons are drawn with: every machine gets the same).
static func _cell_swing(seed: int, ix: int, iy: int, t: float) -> float:
	var s: float = 0.0
	for k in GUST_HZ.size():
		var phase: float = MountainNoise.cell(ix, iy, k, seed) * TAU
		s += GUST_WEIGHT[k] * sin(TAU * GUST_HZ[k] * t + phase)
	return s


## The sample with the local wind in place of the regional one: [param canyon] is Planet.canyon_at's
## answer ({} or {"depth", "axis"}), [param gust] the gust factor, [param cap] the body's gameplay
## ceiling on the wind (ClimateProfile.wind_scale_max_ms). The regional wind stays under
## wind_mean_*; gust_factor, canyon_depth and canyon_axis say what was done.
static func apply(sample: Dictionary, canyon: Dictionary, gust: float, cap: float) -> Dictionary:
	var out: Dictionary = sample.duplicate()
	var east: float = float(sample.get("wind_east_m_s", 0.0))
	var north: float = float(sample.get("wind_north_m_s", 0.0))
	var depth: float = float(canyon.get("depth", 0.0))
	var axis: Vector2 = canyon.get("axis", Vector2.ZERO)
	var local: Vector2 = canyon_wind(east, north, axis, depth) * gust
	if cap > 0.0:
		local = local.limit_length(cap)
	out["wind_mean_east_m_s"] = east
	out["wind_mean_north_m_s"] = north
	out["wind_mean_speed_m_s"] = float(sample.get("wind_speed_m_s", 0.0))
	out["wind_east_m_s"] = local.x
	out["wind_north_m_s"] = local.y
	out["wind_speed_m_s"] = local.length()
	out["wind_from_deg"] = WeatherSampler.wind_from_deg(local.x, local.y)
	out["gust_factor"] = gust
	out["canyon_depth"] = depth
	out["canyon_axis"] = axis
	return out
