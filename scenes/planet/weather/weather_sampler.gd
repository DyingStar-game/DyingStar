class_name WeatherSampler
extends RefCounted
## The weather at ONE point: the climate background plus every weather system in reach — the
## twin of the weather service's `weather-core/src/sampler.rs`, pinned by its golden samples
## (`test/unit/test_weather_sampler.gd`). Pure functions: data in, a Dictionary out. The server and
## every client run this on the same inputs (the ClimateProfile of the body, the WeatherSystem
## objects Horizon delivered), so the wind that pushes the truck on the server is the wind the
## client draws.
##
## Conventions (the service's): east = the direction the body turns toward, which is INcreasing
## longitude in the body frame (HEALPix: lon = atan2(-z, x), the QGIS convention since the planet's
## re-export of 2026-10-08); north = toward the body's +Y pole.
## Winds are (east, north) m/s; `wind_from_deg` is where the wind comes FROM, 0 = north, clockwise.

const BAND_CALM := &"calm"
const BAND_SINGLE_CELL := &"single_cell"
const BAND_TRADES := &"trades"
const BAND_WESTERLIES := &"westerlies"
const BAND_POLAR := &"polar_easterlies"

const KIND_DEPRESSION := &"depression"
const KIND_ANTICYCLONE := &"anticyclone"
const KIND_DUST_STORM := &"dust_storm"
const KIND_RAIN_FRONT := &"rain_front"

## Koschmieder: visibility = 3.912 / β, with the storm dust spread over ~1 km of air.
const DUST_LAYER_M := 1000.0
const NO_DUST_VISIBILITY_M := 1.0e6


## Mean surface wind of the latitude band, as {band, east, north} (m/s). Hadley cell: back to the
## equator, bent west (trades); Ferrel: poleward and east (westerlies); polar: easterlies; one-cell
## worlds flow gently to the equator; the deflection shrinks with the Coriolis parameter.
static func band_wind(profile: ClimateProfile, lat_deg: float) -> Dictionary:
	if not profile.has_atmosphere:
		return {"band": BAND_CALM, "east": 0.0, "north": 0.0}
	var toward_equator: float = -1.0 if lat_deg >= 0.0 else 1.0
	var abs_lat: float = absf(lat_deg)
	var deflection: float = clampf(profile.coriolis_45_s / 1.0e-4, 0.0, 1.0)
	var band: StringName
	var factor: float
	var meridional_sign: float
	var zonal_sign: float
	match profile.cells:
		1:
			band = BAND_SINGLE_CELL
			factor = 0.5
			meridional_sign = toward_equator
			zonal_sign = -1.0
		2:
			if abs_lat < profile.hadley_edge_deg:
				band = BAND_TRADES
				factor = 0.5
				meridional_sign = toward_equator
				zonal_sign = -1.0
			else:
				band = BAND_WESTERLIES
				factor = 1.0
				meridional_sign = -toward_equator
				zonal_sign = 1.0
		_:
			if abs_lat < profile.hadley_edge_deg:
				band = BAND_TRADES
				factor = 0.5
				meridional_sign = toward_equator
				zonal_sign = -1.0
			elif abs_lat < 60.0:
				band = BAND_WESTERLIES
				factor = 1.0
				meridional_sign = -toward_equator
				zonal_sign = 1.0
			else:
				band = BAND_POLAR
				factor = 0.6
				meridional_sign = toward_equator
				zonal_sign = -1.0
	var equator_fade: float = clampf(abs_lat / 5.0, 0.0, 1.0)
	var speed: float = profile.v10_scale_m_s * factor
	if band == BAND_TRADES:
		speed *= equator_fade
	return {
		"band": band,
		"east": speed * deflection * zonal_sign,
		"north": speed * (1.0 - 0.7 * deflection) * meridional_sign,
	}


## Great-circle distance (m) and the bearing from the centre to the point as [distance, east,
## north] unit components, on a sphere of radius `r` (the service's `offset_on_sphere`).
static func offset_on_sphere(r: float, from_lon_deg: float, from_lat_deg: float, to_lon_deg: float,
		to_lat_deg: float) -> Array:
	var lon1: float = deg_to_rad(from_lon_deg)
	var lat1: float = deg_to_rad(from_lat_deg)
	var lon2: float = deg_to_rad(to_lon_deg)
	var lat2: float = deg_to_rad(to_lat_deg)
	var dlon: float = lon2 - lon1
	var a: float = pow(sin((lat2 - lat1) / 2.0), 2.0) + cos(lat1) * cos(lat2) * pow(sin(dlon / 2.0), 2.0)
	var d: float = 2.0 * r * asin(minf(sqrt(a), 1.0))
	# East is the direction of INcreasing longitude in this frame.
	var east: float = sin(dlon) * cos(lat2)
	var north: float = cos(lat2) * sin(lat1) * cos(dlon) * -1.0 + sin(lat2) * cos(lat1)
	var n: float = sqrt(east * east + north * north)
	if n < 1e-12:
		return [d, 0.0, 1.0]
	return [d, east / n, north / n]


## What one system adds at (lon, lat): {east, north, pressure, dust_tau, precipitation, humidity,
## weight}. `system` is the Dictionary a WeatherSystem node reports (see WeatherSystem.state()).
static func contribution(profile: ClimateProfile, system: Dictionary, lon_deg: float, lat_deg: float) -> Dictionary:
	var off: Array = offset_on_sphere(profile.radius_m, system["lon"], system["lat"], lon_deg, lat_deg)
	var r: float = off[0]
	var be: float = off[1]
	var bn: float = off[2]
	var sigma: float = system["sigma_m"]
	var weight: float = exp(-r * r / (2.0 * sigma * sigma))
	if weight < 1e-4:
		return {"east": 0.0, "north": 0.0, "pressure": 0.0, "dust_tau": 0.0, "precipitation": 0.0,
			"humidity": 0.0, "weight": 0.0}
	var intensity: float = system["intensity"]
	# Tangential speed of a Gaussian hump: peaks at r = σ.
	var v_t: float = system["wind_peak"] * intensity * (r / sigma) * exp(0.5 - r * r / (2.0 * sigma * sigma))
	var northern: bool = system["lat"] >= 0.0
	var low: bool = system["kind"] != KIND_ANTICYCLONE
	# Counter-clockwise seen from above (north up, east right): bearing (e, n) -> (-n, e).
	var ccw: bool = low == northern
	var te: float = -bn if ccw else bn
	var tn: float = be if ccw else -be
	var inward: float = -0.3 if low else 0.3
	return {
		"east": v_t * (te + inward * be),
		"north": v_t * (tn + inward * bn),
		"pressure": system["pressure_anomaly_pa"] * weight,
		"dust_tau": system["dust_tau"] * intensity * weight,
		"precipitation": system["precipitation_mm_h"] * intensity * weight,
		"humidity": system["humidity"] * weight,
		"weight": weight,
	}


## The direction a wind (east, north) comes FROM: 0 = from the north, 90 = from the east.
static func wind_from_deg(east: float, north: float) -> float:
	if east == 0.0 and north == 0.0:
		return 0.0
	return fposmod(rad_to_deg(atan2(-east, -north)), 360.0)


## Air density at an altitude, kg/m³ (isothermal column), from the atmosphere profile.
static func air_density(profile: ClimateProfile, altitude_m: float) -> float:
	if not profile.has_atmosphere:
		return 0.0
	return profile.rho0_kg_m3 * exp(-altitude_m / profile.scale_height_m)


## Sample the weather at a point. `systems` are the state Dictionaries of the WeatherSystem nodes
## of the body; `local_solar_hours` and `declination_deg` come from the body (Planet).
static func sample(profile: ClimateProfile, systems: Array, lon_deg: float, lat_deg: float,
		altitude_m: float, local_solar_hours: float, declination_deg: float) -> Dictionary:
	var background: Dictionary = band_wind(profile, lat_deg)
	var we: float = background["east"]
	var wn: float = background["north"]
	var dp: float = 0.0
	var dust: float = 0.0
	var humidity: float = 0.0
	var rain: float = 0.0
	var weighed: Array = []
	for s: Dictionary in systems:
		var k: Dictionary = contribution(profile, s, lon_deg, lat_deg)
		if k["weight"] < 0.01:
			continue
		we += k["east"]
		wn += k["north"]
		dp += k["pressure"]
		dust += k["dust_tau"]
		humidity += k["humidity"]
		rain += k["precipitation"]
		weighed.append([k["weight"], s["id"], s["kind"]])
	weighed.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var raw: float = sqrt(we * we + wn * wn)
	var speed: float = minf(raw, profile.wind_scale_max_ms)
	var scale: float = speed / raw if raw > 0.0 else 1.0
	we *= scale
	wn *= scale
	var column: float = profile.pressure_pa * exp(-altitude_m / profile.scale_height_m) if profile.has_atmosphere else 0.0
	var pressure: float = column + dp
	var visibility: float = 3.912 / (dust / DUST_LAYER_M) if dust > 1e-6 else NO_DUST_VISIBILITY_M
	var density: float = air_density(profile, altitude_m)
	if profile.has_atmosphere and column > 0.0:
		density *= pressure / column
	return {
		"lon_deg": lon_deg,
		"lat_deg": lat_deg,
		"altitude_m": altitude_m,
		"local_solar_hours": local_solar_hours,
		"declination_deg": declination_deg,
		"temperature_k": surface_temperature_k(profile, lat_deg, local_solar_hours, declination_deg),
		"pressure_pa": pressure,
		"pressure_anomaly_pa": dp,
		"air_density_kg_m3": density,
		"wind_east_m_s": we,
		"wind_north_m_s": wn,
		"wind_speed_m_s": speed,
		"wind_from_deg": wind_from_deg(we, wn),
		"dust_tau": dust,
		"visibility_m": visibility,
		"humidity": minf(humidity, 1.0),
		"precipitation_mm_h": rain,
		"band": background["band"],
		"systems": weighed,
	}


## Instantaneous insolation factor: cos of the star's zenith angle, 0 at night.
static func insolation_factor(lat_deg: float, hour_angle: float, decl_deg: float) -> float:
	var lat: float = deg_to_rad(lat_deg)
	var decl: float = deg_to_rad(decl_deg)
	return maxf(sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(hour_angle), 0.0)


## Daily-mean insolation factor at a latitude for a declination (0 in the polar night).
static func daily_mean_insolation_factor(lat_deg: float, decl_deg: float) -> float:
	var lat: float = deg_to_rad(lat_deg)
	var decl: float = deg_to_rad(decl_deg)
	var x: float = -tan(lat) * tan(decl)
	var h0: float = PI if x <= -1.0 else (0.0 if x >= 1.0 else acos(x))
	return maxf((h0 * sin(lat) * sin(decl) + cos(lat) * cos(decl) * sin(h0)) / PI, 0.0)


## Annual mean of the daily factor (12 declinations over the year).
static func annual_mean_insolation_factor(lat_deg: float, obliquity_deg: float) -> float:
	var total: float = 0.0
	for k in 12:
		total += daily_mean_insolation_factor(lat_deg, obliquity_deg * sin(TAU * k / 12.0))
	return total / 12.0


static func hour_angle_rad(local_solar_hours: float) -> float:
	return (local_solar_hours - 12.0) / 24.0 * TAU


## Surface air temperature (K): annual-mean latitude profile (P2), the seasonal departure of the
## daily insolation damped by the heat the ground and the air store, and the day/night swing
## peaking two hours after noon. Twin of `surface_temperature_k` in climate.rs.
static func surface_temperature_k(p: ClimateProfile, lat_deg: float, local_solar_hours: float, decl_deg: float) -> float:
	if p.tidal_locked:
		var day: float = p.t_surface_k + p.diurnal_amplitude_k
		var night: float = p.t_surface_k - p.diurnal_amplitude_k
		return night + (day - night) * insolation_factor(lat_deg, hour_angle_rad(local_solar_hours), decl_deg)
	var x: float = sin(deg_to_rad(lat_deg))
	var t2: float = -p.delta_t_equator_pole_k / 1.5
	var annual: float = p.t_surface_k + t2 * 0.5 * (3.0 * x * x - 1.0)
	var q_today: float = daily_mean_insolation_factor(lat_deg, decl_deg)
	var q_mean: float = annual_mean_insolation_factor(lat_deg, absf(minf(p.tilt_deg, 180.0 - p.tilt_deg)))
	var b_lin: float = 0.55 * 4.0 * 5.670374419e-8 * pow(p.t_eq_k, 3.0)
	var relax_s: float = p.radiative_time_s + p.thermal_inertia_tiu * sqrt(p.orbit_period_s / TAU) / maxf(b_lin, 1e-9)
	var damping: float = 1.0 / sqrt(1.0 + pow(TAU / maxf(p.orbit_period_s, 1.0) * relax_s, 2.0))
	var seasonal: float = (1.0 - p.bond_albedo) * p.irradiance_w_m2 * (q_today - q_mean) / maxf(b_lin, 1e-9) * damping
	var noon_here: float = insolation_factor(lat_deg, 0.0, decl_deg)
	var swing: float = p.diurnal_amplitude_k * noon_here * cos(hour_angle_rad(local_solar_hours) - hour_angle_rad(14.0))
	return annual + seasonal + swing


## East and north unit vectors of the ground at (lon, lat) in the body-fixed frame (the service's
## `local_axes`): east is the direction the body turns toward, INcreasing longitude in this frame
## (HEALPix.lonlat2vec: z = -cos lat sin lon).
static func local_axes(lon_deg: float, lat_deg: float) -> Array:
	var lon: float = deg_to_rad(lon_deg)
	var lat: float = deg_to_rad(lat_deg)
	var east := Vector3(-sin(lon), 0.0, -cos(lon))
	var north := Vector3(-sin(lat) * cos(lon), cos(lat), sin(lat) * sin(lon))
	return [east, north]


## [param sample] with [param override]'s keys in place of its own — a stage dictating the wind
## (Planet.weather_override) — the wind's speed and direction, and the visibility, recomputed when their
## parts were replaced. {} leaves the sample as it is; the input is never written to.
static func with_override(sample: Dictionary, override: Dictionary) -> Dictionary:
	if override.is_empty():
		return sample
	var out: Dictionary = sample.duplicate()
	out.merge(override, true)
	if override.has("wind_east_m_s") or override.has("wind_north_m_s"):
		var east: float = float(out.get("wind_east_m_s", 0.0))
		var north: float = float(out.get("wind_north_m_s", 0.0))
		out["wind_speed_m_s"] = sqrt(east * east + north * north)
		out["wind_from_deg"] = wind_from_deg(east, north)
	if override.has("dust_tau"):
		var tau: float = float(out["dust_tau"])
		out["visibility_m"] = 3.912 / (tau / DUST_LAYER_M) if tau > 1e-6 else NO_DUST_VISIBILITY_M
	return out
