extends GutTest
## ClimateWeather: the climate model behind the planet's weather hook (WeatherSource).


func test_tarsis_3_has_a_climate_and_another_body_none() -> void:
	assert_not_null(ClimateWeather.for_body("tarsis_3"))
	assert_null(ClimateWeather.for_body("no_such_body"))


func test_the_bands_blow_as_the_model_says() -> void:
	var weather := ClimateWeather.for_body("tarsis_3").duplicate() as ClimateWeather
	weather.weather_enabled = false  # the climate's mean winds alone
	# Trades (20° N): from the east, toward the equator, under the dust threshold.
	var trades := weather.sample(null, HEALPix.lonlat2vec(-39.5, 20.0))
	assert_lt(float(trades.wind_east_m_s), 0.0, "the trades blow westward")
	assert_lt(float(trades.wind_north_m_s), 0.0, "and toward the equator in the north")
	assert_lt(float(trades.wind_speed_m_s), float(trades.lift_threshold_m_s), "too weak to lift the sand")
	# Westerlies (45° N): from the west, over the threshold.
	var west := weather.sample(null, HEALPix.lonlat2vec(-39.5, 45.0))
	assert_gt(float(west.wind_east_m_s), 0.0, "the westerlies blow eastward")
	assert_gt(float(west.wind_speed_m_s), float(west.lift_threshold_m_s), "strong enough to lift the sand")
	assert_almost_eq(float(west.lift_threshold_m_s), 5.964, 0.01)
	# The equator is calm.
	assert_almost_eq(float(weather.sample(null, HEALPix.lonlat2vec(10.0, 0.0)).wind_speed_m_s), 0.0, 0.01)


func test_a_sample_carries_the_hook_s_keys_and_the_temperature() -> void:
	var got := ClimateWeather.for_body("tarsis_3").sample(null, Vector3.UP)
	for key: String in ["wind_east_m_s", "wind_north_m_s", "wind_speed_m_s", "wind_from_deg", "dust_tau",
			"lift_threshold_m_s", "air_density_kg_m3", "temperature_k", "pressure_pa"]:
		assert_true(got.has(key), "a sample has %s" % key)
