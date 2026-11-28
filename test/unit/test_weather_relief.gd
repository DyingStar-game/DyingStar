extends GutTest
## WeatherRelief: the weather the relief and the day make (plateau breeze, lee gusts, haze, dust devils,
## dust walls), over Tarsis 3's climate.

const NOON_LON := 0.0  # the star stands over longitude 0: noon there, 18 h at longitude 90

var profile: ClimateProfile
## The air WeatherRelief asks for: the climate's mean winds with the star over NOON_LON, and still clear air.
var _air: Callable
var _still := func(_lon: float, _lat: float) -> Dictionary:
	return {"band": WeatherSampler.BAND_TRADES, "wind_east_m_s": 0.0, "wind_north_m_s": 0.0, "dust_tau": 0.0}


func before_all() -> void:
	profile = ClimateWeather.for_body("tarsis_3").profile
	_air = _air_at(NOON_LON)


## The climate's mean winds under [param live] systems, the star over [param substellar_lon].
func _air_at(substellar_lon: float, live := []) -> Callable:
	return func(lon: float, lat: float) -> Dictionary:
		return WeatherSampler.sample(profile, live, lon, lat, 0.0, WeatherRelief.solar_hours(lon, substellar_lon), 0.0)


## Air blowing ([param east], [param north]) m/s everywhere, carrying [param dust].
func _blowing(east: float, north: float, dust := 0.0) -> Callable:
	return func(_lon: float, _lat: float) -> Dictionary:
		return {"band": WeatherSampler.BAND_TRADES, "wind_east_m_s": east, "wind_north_m_s": north, "dust_tau": dust}


func test_the_breeze_climbs_by_day_and_drains_weaker_at_night() -> void:
	var east_slope := Vector2(WeatherRelief.SLOPE_FULL, 0.0)  # the ground rises toward the east
	var day := WeatherRelief.breeze(east_slope, WeatherSampler.BAND_TRADES, WeatherRelief.BREEZE_PEAK_H)
	assert_almost_eq(day.x, WeatherRelief.BREEZE_M_S, 1e-6, "whole up the slope at the afternoon peak")
	var night := WeatherRelief.breeze(east_slope, WeatherSampler.BAND_TRADES, WeatherRelief.BREEZE_PEAK_H + 12.0)
	assert_almost_eq(night.x, -WeatherRelief.BREEZE_M_S * WeatherRelief.BREEZE_NIGHT_SHARE, 1e-6, "down it, weaker, at night")
	assert_eq(WeatherRelief.breeze(Vector2.ZERO, WeatherSampler.BAND_TRADES, 15.0), Vector2.ZERO, "none on flat ground")
	var polar := WeatherRelief.breeze(east_slope, WeatherSampler.BAND_POLAR, WeatherRelief.BREEZE_PEAK_H)
	assert_almost_eq(polar.x, -WeatherRelief.KATABATIC_M_S, 1e-6, "past the polar edge the slope drains even by day")


func test_the_haze_lies_between_its_two_altitudes() -> void:
	var trades := WeatherSampler.BAND_TRADES
	assert_almost_eq(WeatherRelief.haze(trades, 2000.0, 500.0, 3500.0, 0.6), 0.6, 1e-6, "whole inside the layer")
	assert_almost_eq(WeatherRelief.haze(trades, 0.0, 500.0, 3500.0, 0.6), 0.6 * WeatherRelief.HAZE_UNDER_SHARE, 1e-6, "thin under it")
	assert_eq(WeatherRelief.haze(trades, 4000.0, 500.0, 3500.0, 0.6), 0.0, "none over it: the plateaus stand clear")
	assert_lt(WeatherRelief.haze(WeatherSampler.BAND_WESTERLIES, 2000.0, 500.0, 3500.0, 0.6), 0.6, "thinner outside the trades")


func test_the_wind_gusts_behind_a_massif_in_the_westerlies_only() -> void:
	assert_eq(WeatherRelief.lee_gain(WeatherSampler.BAND_TRADES, 2000.0, 100.0, 1), 1.0)
	assert_eq(WeatherRelief.lee_gain(WeatherSampler.BAND_WESTERLIES, -500.0, 100.0, 1), 1.0, "none before a rise")
	var gain := WeatherRelief.lee_gain(WeatherSampler.BAND_WESTERLIES, 2000.0, 100.0, 1)
	assert_between(gain, 1.0 + WeatherRelief.LEE_GAIN * 0.6, 1.0 + WeatherRelief.LEE_GAIN, "behind a full drop")


func test_dust_devils_whirl_by_day_at_low_latitudes_and_the_same_for_everyone() -> void:
	var at := Vector2(0.0, 3.0)
	var day := WeatherRelief.devils_near(profile, at, 20000.0, 1000.0, 0.0, NOON_LON, _air)
	assert_gt(day.size(), 5, "devils near the equator at noon")
	assert_eq(day, WeatherRelief.devils_near(profile, at, 20000.0, 1000.0, 0.0, NOON_LON, _air), "a pure function")
	var night := WeatherRelief.devils_near(profile, at, 20000.0, 1000.0, 0.0, NOON_LON + 180.0, _air_at(NOON_LON + 180.0))
	assert_eq(night.size(), 0, "none at night")
	assert_eq(WeatherRelief.devils_near(profile, Vector2(0.0, 45.0), 20000.0, 1000.0, 0.0, NOON_LON, _air).size(), 0, "none in the westerlies")
	for devil: Dictionary in day:
		assert_between(float(devil.radius_m), 5.0, 150.0)
		assert_between(float(devil.wind_m_s), 10.0, 30.0)
	if day.is_empty():
		return
	# The wind turns round the centre, strongest at the devil's radius, and the dust is in the core.
	var one: Dictionary = day[0]
	var centre := Vector2(one.lon, one.lat)
	var r := profile.radius_m
	var rim: Array = WeatherRelief.devil_effect(one, WeatherRelief.moved(centre, Vector2(float(one.radius_m), 0.0), r), r)
	assert_almost_eq((rim[0] as Vector2).length(), float(one.wind_m_s) * float(one.strength), 0.01)
	assert_almost_eq(absf((rim[0] as Vector2).y), (rim[0] as Vector2).length(), 0.01, "east of the centre the wind blows north or south")
	var far: Array = WeatherRelief.devil_effect(one, WeatherRelief.moved(centre, Vector2(float(one.radius_m) * 5.0, 0.0), r), r)
	assert_eq(far[0], Vector2.ZERO)
	assert_eq(far[1], 0.0)


func test_a_dust_wall_falls_from_a_cliff_in_the_evening_and_runs_downhill() -> void:
	# A world whose ground rises toward the east everywhere, steeply: every wall runs west.
	var cliff := func(_lon: float, _lat: float) -> Dictionary: return {"height_m": 0.0, "upslope": Vector2(0.3, 0.0)}
	var flat := func(_lon: float, _lat: float) -> Dictionary: return {"height_m": 0.0, "upslope": Vector2.ZERO}
	var at := Vector2(90.0, 10.0)
	var walls := []
	var sun := 0.0
	# Somewhere in the hours the walls fall in, at longitude 90, a wall of these cells is running.
	for step in 40:
		sun = at.x - (WeatherRelief.WALL_FROM_H + step * 0.07 - 12.0) * 15.0
		walls = WeatherRelief.walls_near(profile, at, 0.0, sun, cliff, {}, _still)
		if not walls.is_empty():
			break
	assert_false(walls.is_empty(), "a wall runs in the evening")
	if walls.is_empty():
		return
	var wall: Dictionary = walls[0]
	assert_almost_eq(float(wall.east), -1.0, 1e-6, "down the slope")
	assert_between(float(wall.speed_m_s), 10.0, 18.0)
	assert_eq(WeatherRelief.walls_near(profile, at, 0.0, sun, flat, {}, _still).size(), 0, "none without a cliff")
	assert_eq(WeatherRelief.walls_near(profile, at, 0.0, at.x, cliff, {}, _still).size(), 0, "none at noon")
	# Behind the front: its wind and its dust. Ahead of it: nothing yet.
	var front := Vector2(wall.lon, wall.lat)
	var lead := _lead(wall)  # the drawn front leads its middle: it runs west, so it stands lead m west of it
	var behind: Array = WeatherRelief.wall_effect(wall, WeatherRelief.moved(front, Vector2(200.0 - lead, 0.0), profile.radius_m),
			profile.radius_m)
	assert_lt((behind[0] as Vector2).x, 0.0, "the wall's wind blows the way it runs")
	assert_gt(float(behind[1]), 0.0, "and carries dust")
	var ahead: Array = WeatherRelief.wall_effect(wall, WeatherRelief.moved(front, Vector2(-200.0 - lead, 0.0), profile.radius_m),
			profile.radius_m)
	assert_eq(ahead[1], 0.0)


func test_the_local_weather_is_laid_over_a_sample() -> void:
	var weather := ClimateWeather.for_body("tarsis_3").duplicate() as ClimateWeather
	var base := weather.sample_at(-39.5, 20.0, 0.0, 0.0, -39.5 - 45.0, [])  # 15 h there
	var slope := {"height_m": 2000.0, "upslope": Vector2(0.0, WeatherRelief.SLOPE_FULL)}
	var got := WeatherRelief.apply(base, weather.profile, slope, [], [], Vector3(500.0, 3500.0, 0.6), 0.0)
	assert_almost_eq(float(got.wind_north_m_s), float(base.wind_north_m_s) + WeatherRelief.BREEZE_M_S, 1e-4, "the breeze is added")
	assert_almost_eq(float(got.dust_tau), 0.6, 1e-6, "the haze too")
	assert_almost_eq(float(got.visibility_m), 3.912 / (0.6 / 1000.0), 1.0)
	assert_true((got.phenomena as PackedStringArray).has(WeatherRelief.NAME_BREEZE))
	assert_true((got.phenomena as PackedStringArray).has(WeatherRelief.NAME_HAZE))
	assert_eq(float(base.dust_tau), 0.0, "the sample given is left as it was")
	var top := WeatherRelief.apply(base, weather.profile, {"height_m": 4200.0}, [], [], Vector3(500.0, 3500.0, 0.6), 0.0)
	assert_gt(float(top.updraft_m_s), 0.0, "the air climbs over a sunlit plateau")
	assert_eq(float(top.dust_tau), 0.0, "which stands clear of the haze")


func test_the_service_s_weather_decides_where_devils_stand() -> void:
	var at := Vector2(0.0, 3.0)
	var calm := WeatherRelief.devils_near(profile, at, 20000.0, 1000.0, 0.0, NOON_LON, _blowing(1.0, 0.0))
	assert_gt(calm.size(), 5, "devils in weak wind under a clear sky")
	var windy := WeatherRelief.devils_near(profile, at, 20000.0, 1000.0, 0.0, NOON_LON,
			_blowing(WeatherRelief.DEVIL_CALM_M_S[1] + 1.0, 0.0))
	assert_eq(windy.size(), 0, "none where the service's wind is strong")
	var veiled := WeatherRelief.devils_near(profile, at, 20000.0, 1000.0, 0.0, NOON_LON,
			_blowing(1.0, 0.0, WeatherRelief.DEVIL_VEIL_TAU[1] + 0.5))
	assert_eq(veiled.size(), 0, "none under a storm's dust")
	# A dust storm of the service over the place: the same sampler the game reads says so.
	var storm := {"id": 1, "kind": &"dust_storm", "lon": 0.0, "lat": 3.0, "sigma_m": 300000.0, "intensity": 1.0,
			"pressure_anomaly_pa": -800.0, "wind_peak": 25.0, "dust_tau": 6.0, "precipitation_mm_h": 0.0, "humidity": 0.0}
	assert_eq(WeatherRelief.devils_near(profile, at, 20000.0, 1000.0, 0.0, NOON_LON, _air_at(NOON_LON, [storm])).size(), 0,
			"none inside a dust storm the service sent")


func test_the_service_s_wind_carries_a_wall_or_holds_it() -> void:
	var cliff := func(_lon: float, _lat: float) -> Dictionary: return {"height_m": 0.0, "upslope": Vector2(0.3, 0.0)}
	var at := Vector2(90.0, 10.0)
	var sun := 0.0
	var still := []
	for step in 40:
		sun = at.x - (WeatherRelief.WALL_FROM_H + step * 0.07 - 12.0) * 15.0
		still = WeatherRelief.walls_near(profile, at, 0.0, sun, cliff, {}, _still)
		if not still.is_empty():
			break
	assert_false(still.is_empty(), "a wall runs in still air")
	if still.is_empty():
		return
	# The walls run west here: a wind from the east carries them, one from the west holds them.
	var carried := WeatherRelief.walls_near(profile, at, 0.0, sun, cliff, {}, _blowing(-6.0, 0.0))
	assert_eq(carried.size(), still.size())
	assert_almost_eq(float(carried[0].speed_m_s), float(still[0].speed_m_s) + 6.0, 1e-6, "the wind's push is added")
	assert_eq(WeatherRelief.walls_near(profile, at, 0.0, sun, cliff, {}, _blowing(30.0, 0.0)).size(), 0,
			"held under the speed that lifts dust, no wall")
	assert_eq(WeatherRelief.walls_near(profile, at, 0.0, sun, cliff, {}, _blowing(0.0, 0.0, WeatherRelief.WALL_VEIL_TAU[1])).size(), 0,
			"none in the mixed air of a storm")


## A wall at (0, 0) running east at 12 m/s, its front 20 km long, 1.5 km deep, at full strength.
func _test_wall() -> Dictionary:
	return {"lon": 0.0, "lat": 0.0, "east": 1.0, "north": 0.0, "length_m": 20000.0, "depth_m": 1500.0,
		"strength": 1.0, "speed_m_s": 12.0}


## The wind (east, north) a wall leaves at [param ahead_m] metres ahead of its front (negative: behind)
## over a background wind [param background], as apply lays it.
func _wind_across(wall: Dictionary, ahead_m: float, background: Vector2) -> Vector2:
	var at := WeatherRelief.moved(Vector2(0.0, 0.0), Vector2(ahead_m + _lead(wall), 0.0), profile.radius_m)
	var effect: Array = WeatherRelief.wall_effect(wall, at, profile.radius_m)
	return background * float(effect[2]) + (effect[0] as Vector2)


func test_a_wall_s_gust_front_is_a_ramp_not_a_step() -> void:
	var wall := _test_wall()
	var background := Vector2(-7.0, 0.0)  # from the east, against the wall's way
	var far := _wind_across(wall, WeatherRelief.WALL_LULL_M + 50.0, background)
	assert_eq(far, background, "well ahead: the wind as it was")
	var lull := _wind_across(wall, 30.0, background)
	assert_lt(lull.length(), background.length(), "just ahead: a lull")
	# Every 10 m across the front, no jump: 3 m/s at most from one to the next.
	var last := _wind_across(wall, WeatherRelief.WALL_LULL_M, background)
	var peak := 0.0
	for k in range(int(WeatherRelief.WALL_LULL_M / 10.0), -int(WeatherRelief.WALL_RAMP_M * 3.0 / 10.0), -1):
		var now := _wind_across(wall, k * 10.0, background)
		assert_lt((now - last).length(), 3.0, "no step at %d m" % (k * 10))
		last = now
		var effect: Array = WeatherRelief.wall_effect(wall, WeatherRelief.moved(Vector2.ZERO, Vector2(k * 10.0 + _lead(wall), 0.0),
				profile.radius_m), profile.radius_m)
		peak = maxf(peak, (effect[0] as Vector2).x)
	assert_gt(peak, 12.0, "a gust at the front, stronger than the wall's own wind")
	var dust_front: Array = WeatherRelief.wall_effect(wall, WeatherRelief.moved(Vector2.ZERO, Vector2(_lead(wall) - 5.0, 0.0),
			profile.radius_m), profile.radius_m)
	var dust_in: Array = WeatherRelief.wall_effect(wall, WeatherRelief.moved(Vector2.ZERO,
			Vector2(_lead(wall) - WeatherRelief.WALL_DUST_RAMP_M, 0.0), profile.radius_m), profile.radius_m)
	assert_lt(float(dust_front[1]), float(dust_in[1]), "the dust rises over its ramp")


## How far ahead of the wall's middle (lon, lat) its front stands there (WeatherRelief.front_lead_m).
func _lead(wall: Dictionary) -> float:
	return WeatherRelief.front_lead_m(0.0, float(wall["length_m"]) * 0.5, float(wall["depth_m"]))


## The weather's front is the front drawn: along the whole wall, no dust just ahead of the drawn front's foot,
## dust just behind it (it swallowed a village 500 m before its dust did, 2026-11-28).
func test_the_wall_s_dust_follows_its_drawn_front() -> void:
	var wall := _test_wall()
	var deep := float(wall["depth_m"])
	var size := Vector3(float(wall["length_m"]), 1000.0, deep * WeatherPhenomena.WALL_DEEPER)
	for x: float in [-8000.0, -3000.0, 0.0, 1200.0, 6000.0]:
		# The drawn front's foot, from the box's middle toward its leading face, back to the wall's middle.
		var drawn := WeatherPhenomena.wall_front_m(x, size, deep) - size.z * 0.5 + deep * WeatherPhenomena.WALL_FRONT_MARGIN
		assert_almost_eq(drawn, WeatherRelief.front_lead_m(x, size.x * 0.5, deep), 1e-6, "one front at %.0f m" % x)
		# The wall runs east: "along" is north.
		var ahead := WeatherRelief.moved(Vector2.ZERO, Vector2(drawn + 20.0, x), profile.radius_m)
		var behind := WeatherRelief.moved(Vector2.ZERO, Vector2(drawn - 400.0, x), profile.radius_m)
		assert_eq(float(WeatherRelief.wall_effect(wall, ahead, profile.radius_m)[1]), 0.0, "no dust ahead at %.0f m" % x)
		assert_gt(float(WeatherRelief.wall_effect(wall, behind, profile.radius_m)[1]), 1.0, "dust behind at %.0f m" % x)
	assert_gt(_lead(wall), 100.0, "at the middle the drawn front leads the line through it")


func test_a_wall_s_wind_and_dust_stop_at_its_top() -> void:
	var wall := _test_wall()
	wall["height_m"] = 1000.0
	var at := WeatherRelief.moved(Vector2.ZERO, Vector2(-300.0, 0.0), profile.radius_m)  # behind the front
	var base := {"band": WeatherSampler.BAND_TRADES, "lon_deg": at.x, "lat_deg": at.y, "local_solar_hours": 17.0,
		"wind_east_m_s": -3.0, "wind_north_m_s": 0.0, "dust_tau": 0.0, "declination_deg": 0.0}
	var ground := WeatherRelief.apply(base, profile, {"height_m": 200.0}, [], [wall], Vector3.ZERO, 0.0)
	assert_gt(float(ground.wind_east_m_s), 0.0, "on the ground behind the front: the wall's wind")
	assert_gt(float(ground.dust_tau), 0.0, "and its dust")
	var tall := WeatherRelief.wall_tall(wall)
	var inside := WeatherRelief.over_walls(ground, 200.0 + tall * 0.5)
	assert_eq(float(inside.wind_east_m_s), float(ground.wind_east_m_s), "within its height: the same")
	var over := WeatherRelief.over_walls(ground, 200.0 + tall + WeatherRelief.WALL_TOP_FADE_M + 10.0)
	assert_almost_eq(float(over.wind_east_m_s), -3.0, 1e-3, "over its top: the wind as it was")
	assert_almost_eq(float(over.dust_tau), 0.0, 1e-6, "and no dust")
