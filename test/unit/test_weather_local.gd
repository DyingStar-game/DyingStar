extends GutTest
## WeatherLocal: the weather the relief and the day make (plateau breeze, lee gusts, haze, dust devils,
## dust walls), over Tarsis 3's climate.

const NOON_LON := 0.0  # the star stands over longitude 0: noon there, 18 h at longitude 90

var profile: ClimateProfile


func before_all() -> void:
	profile = ClimateWeather.for_body("tarsis_3").profile


func test_the_breeze_climbs_by_day_and_drains_weaker_at_night() -> void:
	var east_slope := Vector2(WeatherLocal.SLOPE_FULL, 0.0)  # the ground rises toward the east
	var day := WeatherLocal.breeze(east_slope, WeatherSampler.BAND_TRADES, WeatherLocal.BREEZE_PEAK_H)
	assert_almost_eq(day.x, WeatherLocal.BREEZE_M_S, 1e-6, "whole up the slope at the afternoon peak")
	var night := WeatherLocal.breeze(east_slope, WeatherSampler.BAND_TRADES, WeatherLocal.BREEZE_PEAK_H + 12.0)
	assert_almost_eq(night.x, -WeatherLocal.BREEZE_M_S * WeatherLocal.BREEZE_NIGHT_SHARE, 1e-6, "down it, weaker, at night")
	assert_eq(WeatherLocal.breeze(Vector2.ZERO, WeatherSampler.BAND_TRADES, 15.0), Vector2.ZERO, "none on flat ground")
	var polar := WeatherLocal.breeze(east_slope, WeatherSampler.BAND_POLAR, WeatherLocal.BREEZE_PEAK_H)
	assert_almost_eq(polar.x, -WeatherLocal.KATABATIC_M_S, 1e-6, "past the polar edge the slope drains even by day")


func test_the_haze_lies_between_its_two_altitudes() -> void:
	var trades := WeatherSampler.BAND_TRADES
	assert_almost_eq(WeatherLocal.haze(trades, 2000.0, 500.0, 3500.0, 0.6), 0.6, 1e-6, "whole inside the layer")
	assert_almost_eq(WeatherLocal.haze(trades, 0.0, 500.0, 3500.0, 0.6), 0.6 * WeatherLocal.HAZE_UNDER_SHARE, 1e-6, "thin under it")
	assert_eq(WeatherLocal.haze(trades, 4000.0, 500.0, 3500.0, 0.6), 0.0, "none over it: the plateaus stand clear")
	assert_lt(WeatherLocal.haze(WeatherSampler.BAND_WESTERLIES, 2000.0, 500.0, 3500.0, 0.6), 0.6, "thinner outside the trades")


func test_the_wind_gusts_behind_a_massif_in_the_westerlies_only() -> void:
	assert_eq(WeatherLocal.lee_gain(WeatherSampler.BAND_TRADES, 2000.0, 100.0, 1), 1.0)
	assert_eq(WeatherLocal.lee_gain(WeatherSampler.BAND_WESTERLIES, -500.0, 100.0, 1), 1.0, "none before a rise")
	var gain := WeatherLocal.lee_gain(WeatherSampler.BAND_WESTERLIES, 2000.0, 100.0, 1)
	assert_between(gain, 1.0 + WeatherLocal.LEE_GAIN * 0.6, 1.0 + WeatherLocal.LEE_GAIN, "behind a full drop")


func test_dust_devils_whirl_by_day_at_low_latitudes_and_the_same_for_everyone() -> void:
	var at := Vector2(0.0, 3.0)
	var day := WeatherLocal.devils_near(profile, at, 20000.0, 1000.0, 0.0, NOON_LON)
	assert_gt(day.size(), 5, "devils near the equator at noon")
	assert_eq(day, WeatherLocal.devils_near(profile, at, 20000.0, 1000.0, 0.0, NOON_LON), "a pure function")
	assert_eq(WeatherLocal.devils_near(profile, at, 20000.0, 1000.0, 0.0, NOON_LON + 180.0).size(), 0, "none at night")
	assert_eq(WeatherLocal.devils_near(profile, Vector2(0.0, 45.0), 20000.0, 1000.0, 0.0, NOON_LON).size(), 0, "none in the westerlies")
	for devil: Dictionary in day:
		assert_between(float(devil.radius_m), 5.0, 150.0)
		assert_between(float(devil.wind_m_s), 10.0, 30.0)
	if day.is_empty():
		return
	# The wind turns round the centre, strongest at the devil's radius, and the dust is in the core.
	var one: Dictionary = day[0]
	var centre := Vector2(one.lon, one.lat)
	var r := profile.radius_m
	var rim: Array = WeatherLocal.devil_effect(one, WeatherLocal.moved(centre, Vector2(float(one.radius_m), 0.0), r), r)
	assert_almost_eq((rim[0] as Vector2).length(), float(one.wind_m_s) * float(one.strength), 0.01)
	assert_almost_eq(absf((rim[0] as Vector2).y), (rim[0] as Vector2).length(), 0.01, "east of the centre the wind blows north or south")
	var far: Array = WeatherLocal.devil_effect(one, WeatherLocal.moved(centre, Vector2(float(one.radius_m) * 5.0, 0.0), r), r)
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
		sun = at.x - (WeatherLocal.WALL_FROM_H + step * 0.07 - 12.0) * 15.0
		walls = WeatherLocal.walls_near(profile, at, 0.0, sun, cliff, {})
		if not walls.is_empty():
			break
	assert_false(walls.is_empty(), "a wall runs in the evening")
	if walls.is_empty():
		return
	var wall: Dictionary = walls[0]
	assert_almost_eq(float(wall.east), -1.0, 1e-6, "down the slope")
	assert_between(float(wall.speed_m_s), 10.0, 18.0)
	assert_eq(WeatherLocal.walls_near(profile, at, 0.0, sun, flat, {}).size(), 0, "none without a cliff")
	assert_eq(WeatherLocal.walls_near(profile, at, 0.0, at.x, cliff, {}).size(), 0, "none at noon")
	# Behind the front: its wind and its dust. Ahead of it: nothing yet.
	var front := Vector2(wall.lon, wall.lat)
	var behind: Array = WeatherLocal.wall_effect(wall, WeatherLocal.moved(front, Vector2(200.0, 0.0), profile.radius_m), profile.radius_m)
	assert_lt((behind[0] as Vector2).x, 0.0, "the wall's wind blows the way it runs")
	assert_gt(float(behind[1]), 0.0, "and carries dust")
	var ahead: Array = WeatherLocal.wall_effect(wall, WeatherLocal.moved(front, Vector2(-200.0, 0.0), profile.radius_m), profile.radius_m)
	assert_eq(ahead[1], 0.0)


func test_the_local_weather_is_laid_over_a_sample() -> void:
	var weather := ClimateWeather.for_body("tarsis_3").duplicate() as ClimateWeather
	weather.weather_enabled = false
	var base := weather.sample_at(-39.5, 20.0, 0.0, 0.0, 0.0, -39.5 - 45.0)  # 15 h there
	var slope := {"height_m": 2000.0, "upslope": Vector2(0.0, WeatherLocal.SLOPE_FULL)}
	var got := WeatherLocal.apply(base, weather.profile, slope, [], [], Vector3(500.0, 3500.0, 0.6), 0.0)
	assert_almost_eq(float(got.wind_north_m_s), float(base.wind_north_m_s) + WeatherLocal.BREEZE_M_S, 1e-4, "the breeze is added")
	assert_almost_eq(float(got.dust_tau), 0.6, 1e-6, "the haze too")
	assert_almost_eq(float(got.visibility_m), 3.912 / (0.6 / 1000.0), 1.0)
	assert_true((got.phenomena as PackedStringArray).has(WeatherLocal.NAME_BREEZE))
	assert_true((got.phenomena as PackedStringArray).has(WeatherLocal.NAME_HAZE))
	assert_eq(float(base.dust_tau), 0.0, "the sample given is left as it was")
	var top := WeatherLocal.apply(base, weather.profile, {"height_m": 4200.0}, [], [], Vector3(500.0, 3500.0, 0.6), 0.0)
	assert_gt(float(top.updraft_m_s), 0.0, "the air climbs over a sunlit plateau")
	assert_eq(float(top.dust_tau), 0.0, "which stands clear of the haze")
