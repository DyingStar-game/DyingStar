class_name WeatherSynoptic
extends RefCounted
## The dynamic weather: pressure systems (depressions, anticyclones), dust storms and rain fronts that are
## born, drift with the flow of their latitude band and die — a PURE FUNCTION of (climate, time). Twin of
## the weather service's `weather-core/src/synoptic.rs` and `hash.rs`, pinned by its golden systems
## (`test/unit/test_weather_synoptic.gd`): the service and any client compute the same sky, with no state
## and nothing sent.
##
## The planet is cut into slots (latitude bands × longitude slots the size of a real weather system); each
## slot draws, from an integer hash of (seed, slot, epoch), whether a system is born there at each epoch,
## of which kind and how strong; the system drifts with its band's wind and fades out smoothly.

## SplitMix64's constants, as the signed 64-bit integers GDScript holds (the bits are the same).
const _GOLDEN := -7046029254386353131  # 0x9E3779B97F4A7C15
const _MIX_B := -4417276706812531889   # 0xC2B2AE3D27D4EB4F
const _MIX_C := 1609587929392839161    # 0x165667B19E3779F9
const _STEP_1 := -4658895280553007687  # 0xBF58476D1CE4E5B9
const _STEP_2 := -7723592293110705685  # 0x94D049BB133111EB

## Brunt–Väisälä frequency used for the deformation radius, s⁻¹ (an Earth-like troposphere).
const BRUNT_VAISALA := 0.012
## Systems exist in this share of (slot, epoch) draws.
const EXISTENCE := 0.55
## A system lives this share of its slot's period; the rest is quiet.
const LIFE_SHARE := 0.8
## Latitude bands of the lattice: every BAND_STEP_DEG from -75° to 75°.
const BAND_STEP_DEG := 15.0
const BANDS := 11


## x >> n as on an unsigned 64-bit integer (GDScript's >> keeps the sign).
static func _shr(x: int, n: int) -> int:
	return (x >> n) & ((1 << (64 - n)) - 1)


## One SplitMix64 step.
static func splitmix(x: int) -> int:
	var z := x + _GOLDEN
	z = (z ^ _shr(z, 30)) * _STEP_1
	z = (z ^ _shr(z, 27)) * _STEP_2
	return z ^ _shr(z, 31)


## A seed mixed with three integer coordinates into a 64-bit hash.
static func mix(seed: int, a: int, b: int, c: int) -> int:
	var h := splitmix(seed ^ (a * _GOLDEN))
	h = splitmix(h ^ (b * _MIX_B))
	return splitmix(h ^ (c * _MIX_C))


## A hash as a float in [0, 1): its top 53 bits.
static func unit(h: int) -> float:
	return float(_shr(h, 11)) / 9007199254740992.0


## A hash as a float in [-1, 1).
static func signed_unit(h: int) -> float:
	return unit(h) * 2.0 - 1.0


## The lattice and time scale of [param climate]'s systems: {spacing_m (slots along a band, about 2.5
## deformation radii), period_s (lifecycle of a slot)}.
static func lattice(climate: ClimateWeather) -> Dictionary:
	var p := climate.profile
	var f := maxf(p.coriolis_45_s, 1e-7)
	var deformation_m := BRUNT_VAISALA * maxf(climate.tropopause_m, 2000.0) / f
	var spacing := clampf(2.5 * deformation_m, 1500000.0, PI * p.radius_m / 2.0)
	# The cap: with 11 bands, the equatorial band alone gets about 1/7 of the slots.
	var slots_wanted := maxf(maxi(climate.max_systems, 11) / 7.0, 3.0)
	spacing = minf(maxf(spacing, TAU * p.radius_m / slots_wanted), PI * p.radius_m / 2.0)
	# Earth's systems live about 4 days; the time scale stretches with the day.
	var omega := TAU / maxf(p.rotation_period_s, 1.0)
	var period := clampf(4.0 * 86400.0 * ((TAU / 86164.1) / maxf(omega, 1e-7)), 12.0 * 3600.0, 20.0 * 86400.0)
	return {"spacing_m": spacing, "period_s": period}


## Number of longitude slots in the band at [param lat_deg].
static func slots_in_band(spacing_m: float, radius_m: float, lat_deg: float) -> int:
	return maxi(roundi(TAU * radius_m * cos(deg_to_rad(lat_deg)) / spacing_m), 3)


## Every system alive at [param t] (seconds), given the star's declination today (the seasons steer the
## dust storms), as the Dictionaries WeatherSampler.sample takes.
static func systems_at(climate: ClimateWeather, t: float, decl_deg: float) -> Array:
	var out: Array = []
	if climate.profile == null or not climate.profile.has_atmosphere or not climate.weather_enabled:
		return out
	var l := lattice(climate)
	for band in BANDS:
		var slots := slots_in_band(l.spacing_m, climate.profile.radius_m, (band - 5) * BAND_STEP_DEG)
		for slot in slots:
			var s := system_in_slot(climate, l, band, slot, slots, t, decl_deg)
			if not s.is_empty():
				out.append(s)
	return out


## The system of one slot at [param t], {} when none is alive.
static func system_in_slot(climate: ClimateWeather, l: Dictionary, band: int, slot: int, slots: int, t: float,
		decl_deg: float) -> Dictionary:
	var p := climate.profile
	var seed := p.weather_seed
	var period: float = l.period_s
	var lat := (band - 5) * BAND_STEP_DEG
	# Each slot runs its own clock, offset by a hashed phase, so births are spread over time.
	var phase := unit(mix(seed, band, slot, 0)) * period
	var epoch := floori((t - phase) / period)
	var born := epoch * period + phase
	var life := LIFE_SHARE * period
	var dies := born + life
	if t < born or t >= dies:
		return {}
	var key := band * 100003 + slot
	if unit(mix(seed, key, epoch, 1)) >= EXISTENCE:
		return {}
	# Kind: half lows, half highs; on a dusty world a low in the season of strong sun becomes a dust storm;
	# on a wet world it carries rain.
	var low := unit(mix(seed, key, epoch, 2)) < 0.5
	var season := clampf(WeatherSampler.daily_mean_insolation_factor(lat, decl_deg) / 0.35, 0.0, 1.5)
	var kind := WeatherSampler.KIND_ANTICYCLONE
	if low:
		var r := unit(mix(seed, key, epoch, 3))
		if climate.humidity_inventory < 0.3 and r < climate.dust_lift_bias * season * 0.8:
			kind = WeatherSampler.KIND_DUST_STORM
		elif climate.humidity_inventory >= 0.3 and r < climate.humidity_inventory:
			kind = WeatherSampler.KIND_RAIN_FRONT
		else:
			kind = WeatherSampler.KIND_DEPRESSION
	var peak := 0.5 + 0.5 * unit(mix(seed, key, epoch, 4))
	# Envelope: a smooth hump for pressure systems; a dust storm rises in about 2 h, holds, and fades over
	# about 4 h.
	var age := t - born
	var intensity := peak
	if kind == WeatherSampler.KIND_DUST_STORM:
		var rise := minf(2.0 * 3600.0, life / 4.0)
		var fall := minf(4.0 * 3600.0, life / 3.0)
		var x := clampf(minf(age / rise, (dies - t) / fall), 0.0, 1.0)
		intensity *= x * x * (3.0 - 2.0 * x)
	else:
		intensity *= pow(sin(PI * age / life), 2.0)
	# Birth place: the slot centre, jittered; drift with the flow of the band (systems ride at about half
	# the jet, in the sense of the band's surface wind).
	var slot_width_deg := 360.0 / slots
	var lon0 := (slot + 0.5) * slot_width_deg + signed_unit(mix(seed, key, epoch, 5)) * 0.4 * slot_width_deg
	var lat0 := lat + signed_unit(mix(seed, key, epoch, 6)) * 0.4 * BAND_STEP_DEG
	var zonal_sense := 1.0 if float(WeatherSampler.band_wind(p, lat0)["east"]) >= 0.0 else -1.0
	var drift_east := zonal_sense * 0.5 * climate.u_jet_m_s * (0.5 + 0.5 * unit(mix(seed, key, epoch, 7)))
	var drift_north := 0.2 * absf(drift_east) * signed_unit(mix(seed, key, epoch, 8))
	var cos_lat := maxf(cos(deg_to_rad(lat0)), 0.05)
	var lon := lon0 + rad_to_deg(drift_east * age / (p.radius_m * cos_lat))
	var lat_now := clampf(lat0 + rad_to_deg(drift_north * age / p.radius_m), -85.0, 85.0)
	var sigma: float = 0.25 * float(l.spacing_m) * (0.6 + 0.4 * unit(mix(seed, key, epoch, 9)))
	# Pressure: a deep Earth low is about 3 % of the surface pressure; the share shrinks with the thermal
	# contrast a massive air allows.
	var dp_max := 0.03 * p.pressure_pa * clampf(p.delta_t_equator_pole_k / 35.0, 0.2, 1.5)
	# Wind around a Gaussian pressure hump: the geostrophic peak at r = σ, or the cyclostrophic bound when
	# Coriolis is too weak to balance it; capped by the data.
	var f := maxf(p.coriolis_45_s, 1e-7) * maxf(absf(sin(deg_to_rad(lat0))), 0.15) / sin(deg_to_rad(45.0))
	var geostrophic := dp_max * peak * exp(-0.5) / (p.rho0_kg_m3 * f * sigma)
	var cyclostrophic := sqrt(dp_max * peak / p.rho0_kg_m3)
	var dusty := kind == WeatherSampler.KIND_DUST_STORM
	var rainy := kind == WeatherSampler.KIND_RAIN_FRONT
	var humidity := climate.humidity_inventory
	if kind == WeatherSampler.KIND_DEPRESSION:
		humidity *= 0.5
	elif kind == WeatherSampler.KIND_ANTICYCLONE:
		humidity *= 0.2
	elif dusty:
		humidity = 0.0
	var wrapped := fposmod(lon + 180.0, 360.0) - 180.0
	return {
		"id": mix(seed, key, epoch, 0),
		"name": "",
		"kind": kind,
		"lon": 180.0 if wrapped == -180.0 else wrapped,
		"lat": lat_now,
		"sigma_m": sigma,
		"intensity": intensity,
		"pressure_anomaly_pa": (1.0 if kind == WeatherSampler.KIND_ANTICYCLONE else -1.0) * dp_max * intensity,
		"wind_peak": minf(minf(geostrophic, cyclostrophic), p.wind_scale_max_ms),
		"dust_tau": p.dust_tau_max * peak if dusty else 0.0,
		"precipitation_mm_h": 2.0 + 8.0 * peak if rainy else 0.0,
		"humidity": humidity,
		"born_at": born,
		"dies_at": dies,
	}
