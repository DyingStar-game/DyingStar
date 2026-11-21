class_name WeatherRelief
extends RefCounted
## The weather the relief and the day make, laid over the climate's (WeatherSampler, WeatherSynoptic): the
## local phenomena of the report « De l'atmosphère de Sandbox ».
##
## - Plateau breeze: the air climbs the slopes toward the warm plateaus by day (most at BREEZE_PEAK_H) and
##   drains down them at night, weaker. Past the polar edge it drains all day (polar slope winds).
## - Lee gusts: in the westerlies, the wind tumbling down behind a massif blows harder, in gusts.
## - Permanent haze: the corundum dust the trades keep in the air between two altitudes.
## - Dust devils: whirls a few minutes long over sunlit ground in weak wind, low latitudes.
## - Dust walls: in the late afternoon and early evening the cold air of a plateau falls down its cliffs and runs out over the
##   basin as a front loaded with dust, thinning as it goes.
##
## Pure functions, as the rest of the weather: the same place and instant give the same weather to every
## player. The relief comes in as plain numbers ([method apply]'s terrain) or a Callable, never a scene.
## Places are (longitude, latitude) in degrees; winds are Vector2(east, north) in m/s.

## Breeze: speed up a full slope at its afternoon peak (m/s), the hour of that peak, the share of it the
## night drainage reaches, and the slope (rise per metre along the ground) that gives it whole.
const BREEZE_M_S := 6.0
const BREEZE_PEAK_H := 15.0
const BREEZE_NIGHT_SHARE := 0.6
const SLOPE_FULL := 0.2
## Polar slope winds: speed down a full slope, m/s.
const KATABATIC_M_S := 15.0

## Lee gusts: the wind's gain behind a drop of LEE_FULL_M (the ground upwind stands that much higher), and
## how long a gust lasts (s).
const LEE_GAIN := 1.5
const LEE_FULL_M := 1500.0
const GUST_S := 20.0

## Haze: its share under the layer, in the westerlies and at the poles (1 in the layer, at low latitudes),
## and the height its edges fade over (m).
const HAZE_UNDER_SHARE := 0.35
const HAZE_WESTERLIES_SHARE := 0.5
const HAZE_POLAR_SHARE := 0.25
const HAZE_EDGE_M := 300.0
## Dry convection over a sunlit ground standing above the haze: the air's climb at the zenith, m/s.
const UPDRAFT_M_S := 3.0

## Dust devils: one may be born per cell of DEVIL_CELL_M (m) and DEVIL_LIFE_S (s), DEVIL_SHARE of them are.
## They need the sun (its height's sine from DEVIL_SUN[0], whole at [1]) and weak wind (whole under
## DEVIL_CALM_M_S[0], none past [1]). Radius, height (m) and wind (m/s): from the smallest to the largest.
const DEVIL_CELL_M := 1500.0
const DEVIL_LIFE_S := 300.0
const DEVIL_SHARE := 0.05
const DEVIL_SUN := [0.35, 0.7]
const DEVIL_CALM_M_S := [4.0, 7.0]
const DEVIL_RADIUS_M := [5.0, 150.0]
const DEVIL_HEIGHT_M := [100.0, 2500.0]
const DEVIL_WIND_M_S := [10.0, 30.0]
const DEVIL_TAU := 1.5
## A devil's wind is felt out to this many radii.
const DEVIL_REACH := 4.0

## Dust walls: one may fall per cell of WALL_CELL_M and evening, WALL_SHARE of them do, between WALL_FROM_H
## and WALL_FROM_H + WALL_SPREAD_H (local solar hours), from the steepest of WALL_TRIES places of the cell
## when it is at least WALL_MIN_SLOPE. It lives WALL_LIFE_S, rising over WALL_RISE_S. Speed (m/s), length
## along the front and height (m): from the smallest to the largest. The dusty air behind the front is
## WALL_DEPTH_M deep, plus WALL_SPREAD of the way it has run.
const WALL_CELL_M := 30000.0
const WALL_SHARE := 0.6
const WALL_FROM_H := 16.5
const WALL_SPREAD_H := 1.5
const WALL_LIFE_S := 2400.0
const WALL_RISE_S := 180.0
## A wall is born small and grows over WALL_RISE_S; from WALL_SPENT_FROM of its life on it thins out.
const WALL_SPENT_FROM := 0.55
const WALL_TRIES := 6
const WALL_MIN_SLOPE := 0.08
const WALL_SPEED_M_S := [10.0, 18.0]
const WALL_LENGTH_M := [15000.0, 50000.0]
const WALL_HEIGHT_M := [500.0, 3000.0]
const WALL_DEPTH_M := 1500.0
const WALL_SPREAD := 0.05
const WALL_TAU := 3.0
## Cells around a place a wall may have run in from.
const WALL_REACH_CELLS := 2

const _SEED_DEVIL := 0x44455649
const _SEED_WALL := 0x57414C4C
const _SEED_GUST := 0x47555354

const NAME_BREEZE := &"plateau_breeze"
const NAME_KATABATIC := &"slope_wind"
const NAME_LEE := &"lee_gusts"
const NAME_HAZE := &"haze"
const NAME_DEVIL := &"dust_devil"
const NAME_WALL := &"dust_wall"


## Local solar time (hours) at a longitude, the star standing over [param substellar_lon_deg].
static func solar_hours(lon_deg: float, substellar_lon_deg: float) -> float:
	return fposmod((lon_deg - substellar_lon_deg) / 360.0 * 24.0 + 12.0, 24.0)


## True where the low-latitude phenomena live (the Hadley cell and one-cell worlds).
static func is_low_band(band: StringName) -> bool:
	return band == WeatherSampler.BAND_TRADES or band == WeatherSampler.BAND_CALM \
			or band == WeatherSampler.BAND_SINGLE_CELL


## The breeze of a slope ([param upslope]: the ground's rise per metre toward the east and the north), at
## [param hours] of local solar time.
static func breeze(upslope: Vector2, band: StringName, hours: float) -> Vector2:
	var steep := upslope.length()
	if steep < 1e-6:
		return Vector2.ZERO
	var along := upslope / steep * clampf(steep / SLOPE_FULL, 0.0, 1.0)
	if band == WeatherSampler.BAND_POLAR:
		return -along * KATABATIC_M_S
	var swing := cos((hours - BREEZE_PEAK_H) / 24.0 * TAU)
	return along * BREEZE_M_S * (swing if swing > 0.0 else swing * BREEZE_NIGHT_SHARE)


## How much harder the wind blows behind a drop of [param upwind_drop_m] at [param t]: 1 outside the
## westerlies or on open ground.
static func lee_gain(band: StringName, upwind_drop_m: float, t: float, seed: int) -> float:
	if band != WeatherSampler.BAND_WESTERLIES or upwind_drop_m <= 0.0:
		return 1.0
	var slot := floori(t / GUST_S)
	var a := WeatherSynoptic.unit(WeatherSynoptic.mix(seed + _SEED_GUST, slot, 0, 0))
	var b := WeatherSynoptic.unit(WeatherSynoptic.mix(seed + _SEED_GUST, slot + 1, 0, 0))
	var gust := lerpf(a, b, smoothstep(0.0, 1.0, t / GUST_S - slot))
	return 1.0 + LEE_GAIN * clampf(upwind_drop_m / LEE_FULL_M, 0.0, 1.0) * (0.6 + 0.4 * gust)


## The permanent haze's optical depth over a ground at [param height_m], the layer lying between
## [param base_m] and [param top_m] and worth [param tau] inside.
static func haze(band: StringName, height_m: float, base_m: float, top_m: float, tau: float) -> float:
	var share := 1.0 if is_low_band(band) else \
			(HAZE_WESTERLIES_SHARE if band == WeatherSampler.BAND_WESTERLIES else HAZE_POLAR_SHARE)
	var under := lerpf(HAZE_UNDER_SHARE, 1.0, smoothstep(base_m - HAZE_EDGE_M, base_m, height_m))
	return tau * share * under * (1.0 - smoothstep(top_m, top_m + HAZE_EDGE_M, height_m))


## The lattice cell holding a place, cells [param cell_m] across: (index along its row, row, cells in the row).
static func cell_of(lon_deg: float, lat_deg: float, cell_m: float, radius_m: float) -> Vector3i:
	var row := floori(deg_to_rad(lat_deg) * radius_m / cell_m)
	var count := _row_count(row, cell_m, radius_m)
	return Vector3i(posmod(floori((lon_deg + 180.0) / 360.0 * count), count), row, count)


static func _row_count(row: int, cell_m: float, radius_m: float) -> int:
	return maxi(1, roundi(TAU * radius_m * cos((row + 0.5) * cell_m / radius_m) / cell_m))


## The place at the share ([param fx], [param fy]) of a cell.
static func _cell_place(i: int, row: int, count: int, fx: float, fy: float, cell_m: float, radius_m: float) -> Vector2:
	return Vector2(-180.0 + (i + fx) / count * 360.0, rad_to_deg((row + fy) * cell_m / radius_m))


## Metres east and north from one place to another near it.
static func offset_m(from: Vector2, to: Vector2, radius_m: float) -> Vector2:
	return Vector2(deg_to_rad(wrapf(to.x - from.x, -180.0, 180.0)) * cos(deg_to_rad(from.y)), deg_to_rad(to.y - from.y)) * radius_m


## The place [param by] metres (east, north) from [param from].
static func moved(from: Vector2, by: Vector2, radius_m: float) -> Vector2:
	return Vector2(from.x + rad_to_deg(by.x / (radius_m * maxf(cos(deg_to_rad(from.y)), 0.01))),
			from.y + rad_to_deg(by.y / radius_m))


## The cells of a lattice within [param reach_m] of a place, as [i, row, count].
static func _cells_near(at: Vector2, reach_m: float, cell_m: float, radius_m: float) -> Array:
	var out := []
	var here := cell_of(at.x, at.y, cell_m, radius_m)
	var rows := ceili(reach_m / cell_m)
	for row in range(here.y - rows, here.y + rows + 1):
		if absf((row + 0.5) * cell_m / radius_m) >= PI / 2.0:
			continue
		var count := _row_count(row, cell_m, radius_m)
		var mid := floori((at.x + 180.0) / 360.0 * count)
		var span := mini(ceili(reach_m / cell_m) + 1, count / 2)
		for i in range(mid - span, mid + span + 1):
			out.append([posmod(i, count), row, count])
	return out


## The dust devils alive at [param t] within [param range_m] of a place, each as {id, lon, lat, radius_m,
## height_m, wind_m_s, spin (+1 / -1), strength (0–1)}.
static func devils_near(profile: ClimateProfile, at: Vector2, range_m: float, t: float, decl_deg: float,
		substellar_lon_deg: float) -> Array:
	var out := []
	var r := profile.radius_m
	for cell: Array in _cells_near(at, range_m, DEVIL_CELL_M, r):
		var phase := WeatherSynoptic.unit(WeatherSynoptic.mix(profile.weather_seed + _SEED_DEVIL, cell[0], cell[1], -1)) * DEVIL_LIFE_S
		var slot := floori((t + phase) / DEVIL_LIFE_S)
		var h := WeatherSynoptic.mix(profile.weather_seed + _SEED_DEVIL, cell[0], cell[1], slot)
		if WeatherSynoptic.unit(h) >= DEVIL_SHARE:
			continue
		var draws := _draws(h, 4)
		var place := _cell_place(cell[0], cell[1], cell[2], draws[0], draws[1], DEVIL_CELL_M, r)
		var wind := WeatherSampler.band_wind(profile, place.y)
		if not is_low_band(wind["band"]):
			continue
		var air := Vector2(wind["east"], wind["north"])
		var age := t + phase - slot * DEVIL_LIFE_S
		place = moved(place, air * (age - DEVIL_LIFE_S * 0.5), r)
		var sun := WeatherSampler.insolation_factor(place.y,
				WeatherSampler.hour_angle_rad(solar_hours(place.x, substellar_lon_deg)), decl_deg)
		var strength := sin(PI * age / DEVIL_LIFE_S) * smoothstep(DEVIL_SUN[0], DEVIL_SUN[1], sun) \
				* (1.0 - smoothstep(DEVIL_CALM_M_S[0], DEVIL_CALM_M_S[1], air.length()))
		if strength < 0.05 or offset_m(at, place, r).length() > range_m:
			continue
		var size: float = draws[2]
		out.append({"id": h, "lon": place.x, "lat": place.y, "strength": strength,
				"radius_m": lerpf(DEVIL_RADIUS_M[0], DEVIL_RADIUS_M[1], size * size),
				"height_m": lerpf(DEVIL_HEIGHT_M[0], DEVIL_HEIGHT_M[1], size * sqrt(size)),
				"wind_m_s": lerpf(DEVIL_WIND_M_S[0], DEVIL_WIND_M_S[1], size),
				"spin": 1.0 if draws[3] < 0.5 else -1.0})
	return out


## What a devil adds at a place: [wind (east, north), dust optical depth]. A whirl: the wind turns round
## the centre, strongest at the devil's radius.
static func devil_effect(devil: Dictionary, at: Vector2, radius_m: float) -> Array:
	var d := offset_m(Vector2(devil["lon"], devil["lat"]), at, radius_m)
	var core: float = devil["radius_m"]
	var away := d.length()
	if away > core * DEVIL_REACH or away < 0.01:
		return [Vector2.ZERO, DEVIL_TAU * float(devil["strength"]) if away < 0.01 else 0.0]
	var speed: float = float(devil["wind_m_s"]) * float(devil["strength"]) * (away / core if away < core else core / away)
	return [Vector2(-d.y, d.x) / away * speed * float(devil["spin"]),
			DEVIL_TAU * float(devil["strength"]) * (1.0 - smoothstep(core, core * 2.0, away))]


## The dust walls running at [param t] that may reach a place, each as {id, lon, lat (the middle of the
## front now), east, north (the way it runs, unit), speed_m_s, length_m, height_m, depth_m, strength,
## grown (0 at its birth, 1 once risen), spent (0 until it starts thinning out, 1 at its end)}.
## [param terrain_of]: Callable(lon_deg, lat_deg) -> {height_m, upslope: Vector2}. [param known] keeps
## where each cell's wall falls from, by [i, row, day]: pass the same Dictionary again.
static func walls_near(profile: ClimateProfile, at: Vector2, t: float, substellar_lon_deg: float,
		terrain_of: Callable, known: Dictionary) -> Array:
	var out := []
	var r := profile.radius_m
	var day_s := maxf(profile.rotation_period_s, 1.0)
	for cell: Array in _cells_near(at, WALL_CELL_M * WALL_REACH_CELLS, WALL_CELL_M, r):
		var mid := _cell_place(cell[0], cell[1], cell[2], 0.5, 0.5, WALL_CELL_M, r)
		if absf(mid.y) >= 60.0:
			continue  # past the polar edge the slopes drain all day (breeze)
		var hours := solar_hours(mid.x, substellar_lon_deg)
		var day := roundi((t - hours / 24.0 * day_s) / day_s)
		var h := WeatherSynoptic.mix(profile.weather_seed + _SEED_WALL, cell[0], cell[1], day)
		if WeatherSynoptic.unit(h) >= WALL_SHARE:
			continue
		var draws := _draws(h, 2 + WALL_TRIES * 2)
		var age := (hours - WALL_FROM_H - draws[0] * WALL_SPREAD_H) / 24.0 * day_s
		if age <= 0.0 or age >= WALL_LIFE_S:
			continue
		var key := [cell[0], cell[1], day]
		if not known.has(key):
			known[key] = _wall_source(cell, draws, terrain_of, r)
		var source: Array = known[key]
		if source.is_empty():
			continue
		var size: float = draws[1]
		var way: Vector2 = source[1]
		var speed := lerpf(WALL_SPEED_M_S[0], WALL_SPEED_M_S[1], size)
		var front := moved(source[0], way * speed * age, r)
		out.append({"id": h, "lon": front.x, "lat": front.y, "east": way.x, "north": way.y, "speed_m_s": speed,
				"length_m": lerpf(WALL_LENGTH_M[0], WALL_LENGTH_M[1], size),
				"height_m": lerpf(WALL_HEIGHT_M[0], WALL_HEIGHT_M[1], size),
				"depth_m": WALL_DEPTH_M + WALL_SPREAD * speed * age,
				"strength": smoothstep(0.0, WALL_RISE_S, age) * (1.0 - age / WALL_LIFE_S),
				"grown": smoothstep(0.0, WALL_RISE_S, age), "spent": smoothstep(WALL_SPENT_FROM, 1.0, age / WALL_LIFE_S)})
	return out


## Where a cell's wall falls from: [place, the way down (unit)] at the steepest of its tries, [] when
## none is steep enough.
static func _wall_source(cell: Array, draws: PackedFloat64Array, terrain_of: Callable, radius_m: float) -> Array:
	var best := []
	var steepest := WALL_MIN_SLOPE
	for k in WALL_TRIES:
		var place := _cell_place(cell[0], cell[1], cell[2], draws[2 + k * 2], draws[3 + k * 2], WALL_CELL_M, radius_m)
		var upslope: Vector2 = (terrain_of.call(place.x, place.y) as Dictionary).get("upslope", Vector2.ZERO)
		if upslope.length() >= steepest:
			steepest = upslope.length()
			best = [place, -upslope.normalized()]
	return best


## What a wall adds at a place: [wind (east, north), dust optical depth]. The dusty air lies behind the
## front, thickest right behind it, thinning toward the front's two ends.
static func wall_effect(wall: Dictionary, at: Vector2, radius_m: float) -> Array:
	var d := offset_m(Vector2(wall["lon"], wall["lat"]), at, radius_m)
	var way := Vector2(wall["east"], wall["north"])
	var behind := -d.dot(way)
	var aside := absf(d.dot(Vector2(-way.y, way.x)))
	var half: float = float(wall["length_m"]) * 0.5
	if behind < 0.0 or behind > float(wall["depth_m"]) or aside > half:
		return [Vector2.ZERO, 0.0]
	var share: float = float(wall["strength"]) * (1.0 - behind / float(wall["depth_m"])) \
			* (1.0 - smoothstep(half * 0.8, half, aside))
	return [way * float(wall["speed_m_s"]) * share, WALL_TAU * share]


## [param count] numbers in [0, 1) drawn after the hash [param h].
static func _draws(h: int, count: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(count)
	for k in count:
		h = WeatherSynoptic.splitmix(h)
		out[k] = WeatherSynoptic.unit(h)
	return out


## [param sample] (WeatherSampler's keys, at one place) with the local weather laid over it: the wind,
## its speed and direction, the dust and the visibility again, and "haze_tau", "updraft_m_s" and
## "phenomena" (the names of what is felt there). [param terrain]: {height_m, upslope: Vector2,
## upwind_drop_m}. [param haze_layer]: (base, top, optical depth). The input is not written to.
static func apply(sample: Dictionary, profile: ClimateProfile, terrain: Dictionary, devils: Array, walls: Array,
		haze_layer: Vector3, t: float) -> Dictionary:
	var out := sample.duplicate()
	var band: StringName = sample["band"]
	var at := Vector2(sample["lon_deg"], sample["lat_deg"])
	var hours: float = sample["local_solar_hours"]
	var height: float = terrain.get("height_m", 0.0)
	var names := PackedStringArray()
	var gain := lee_gain(band, float(terrain.get("upwind_drop_m", 0.0)), t, profile.weather_seed)
	var slope := breeze(terrain.get("upslope", Vector2.ZERO), band, hours)
	var wind := Vector2(sample["wind_east_m_s"], sample["wind_north_m_s"]) * gain + slope
	if gain > 1.05:
		names.append(NAME_LEE)
	if slope.length() > 0.5:
		names.append(NAME_KATABATIC if band == WeatherSampler.BAND_POLAR else NAME_BREEZE)
	var veil := haze(band, height, haze_layer.x, haze_layer.y, haze_layer.z)
	var dust: float = float(sample["dust_tau"]) + veil
	if veil > 0.05:
		names.append(NAME_HAZE)
	for group: Array in [[devils, devil_effect, NAME_DEVIL], [walls, wall_effect, NAME_WALL]]:
		for one: Dictionary in group[0]:
			var effect: Array = (group[1] as Callable).call(one, at, profile.radius_m)
			wind += effect[0]
			dust += effect[1]
			if float(effect[1]) > 0.05 and not names.has(group[2]):
				names.append(group[2])
	var speed := minf(wind.length(), profile.wind_scale_max_ms)
	if wind.length() > speed:
		wind = wind.normalized() * speed
	out["wind_east_m_s"] = wind.x
	out["wind_north_m_s"] = wind.y
	out["wind_speed_m_s"] = speed
	out["wind_from_deg"] = WeatherSampler.wind_from_deg(wind.x, wind.y)
	out["dust_tau"] = dust
	out["visibility_m"] = 3.912 / (dust / WeatherSampler.DUST_LAYER_M) if dust > 1e-6 else WeatherSampler.NO_DUST_VISIBILITY_M
	out["haze_tau"] = veil
	var sun := WeatherSampler.insolation_factor(at.y, WeatherSampler.hour_angle_rad(hours), float(sample["declination_deg"]))
	out["updraft_m_s"] = UPDRAFT_M_S * sun if is_low_band(band) and height >= haze_layer.y else 0.0
	out["phenomena"] = names
	return out
