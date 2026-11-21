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


func test_the_trench_is_read_as_the_prototype_asks() -> void:
	# No corundum network: no canyon at all. With one, a place on the open plateau has depth 0.
	var bare := PlanetData.new()
	assert_eq(WeatherCanyon.at(bare, Vector3.UP), {}, "no crack network, no canyon")
	# The trench fades out above its floor over its own depth.
	var data := PlanetData.new()
	data.radius = 6356000.0
	data.corundum_default_biome = true
	var found := {}
	var where := Vector3.ZERO
	for k in 4000:
		var dir := HEALPix.lonlat2vec(-41.3 + k * 0.00002, 20.0)
		var got := WeatherCanyon.at(data, dir)
		if float(got.get("depth", 0.0)) > 0.0 and (got["axis"] as Vector2) != Vector2.ZERO:
			found = got
			where = dir
			break
	assert_false(found.is_empty(), "a trench is met along 9 km of plateau")
	if found.is_empty():
		return
	assert_almost_eq((found["axis"] as Vector2).length(), 1.0, 1e-6, "its direction is a unit (east, north)")
	assert_eq(float(WeatherCanyon.at(data, where, data.crack_depth_m * 2.0)["depth"]), 0.0, "nothing of it above the plateau")
	# Walking along the trench's direction stays in the trench; across it, leaves it.
	var axes: Array = Planet.local_axes(where)
	var axis: Vector2 = found["axis"]
	var along: Vector3 = (axes[0] as Vector3) * axis.x + (axes[1] as Vector3) * axis.y
	var across: Vector3 = along.cross(where)
	var step := data.crack_width_m * 1.5 / data.radius
	assert_gt(float(WeatherCanyon.at(data, (where + along * step * 0.3).normalized())["depth"]), 0.0, "still in it a few metres along")
	assert_eq(float(WeatherCanyon.at(data, (where + across * step).normalized())["depth"])
			* float(WeatherCanyon.at(data, (where - across * step).normalized())["depth"]), 0.0, "out of it across, on one side at least")
