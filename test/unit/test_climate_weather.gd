extends GutTest
## ClimateWeather: the weather service's weather behind the planet's weather hook (WeatherSource).


func test_tarsis_3_has_a_climate_and_another_body_none() -> void:
	assert_not_null(ClimateWeather.for_body("tarsis_3"))
	assert_null(ClimateWeather.for_body("no_such_body"))


func test_the_bands_blow_as_the_model_says() -> void:
	var weather := ClimateWeather.for_body("tarsis_3").duplicate() as ClimateWeather
	# Trades (20° N): from the east, toward the equator, under the dust threshold.
	var trades := weather.sample(null, HEALPix.lonlat2vec(-39.5, 20.0))
	assert_lt(float(trades.wind_east_m_s), 0.0, "the trades blow westward")
	assert_lt(float(trades.wind_north_m_s), 0.0, "and toward the equator in the north")
	assert_lt(float(trades.wind_speed_m_s), float(trades.lift_threshold_m_s), "too weak to lift the sand")
	# Westerlies (45° N): from the west, over the threshold.
	var west := weather.sample(null, HEALPix.lonlat2vec(-39.5, 45.0))
	assert_gt(float(west.wind_east_m_s), 0.0, "the westerlies blow eastward")
	assert_gt(float(west.wind_speed_m_s), float(west.lift_threshold_m_s), "strong enough to lift the sand")
	assert_almost_eq(float(west.lift_threshold_m_s), 5.985, 0.01)
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


func test_the_service_s_systems_give_the_service_s_weather() -> void:
	# What the service answered at one instant (recorded): its systems fed in, the hook must say what its
	# own /point said at ten places.
	var recorded: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/data/weather/sandbox_service_answers.json"))
	var states := WeatherService.states_of(str(recorded["systems_answer"]))
	assert_eq(states.size(), 23, "every system of the answer is read")
	assert_eq(states[0]["id"], "7305473222721446415", "ids are read whole, as text")
	var weather := ClimateWeather.for_body("tarsis_3").duplicate() as ClimateWeather
	weather.feed(states)
	assert_eq(weather.systems(null).size(), 23)
	for expected: Dictionary in recorded["points"]:
		var lon := float(expected["lon_deg"])
		var substellar := lon - (float(expected["local_solar_hours"]) - 12.0) * 15.0
		var got := weather.sample_at(lon, float(expected["lat_deg"]), 0.0, float(expected["declination_deg"]), substellar,
				weather.systems(null))
		var where := "at lon %.1f lat %.1f" % [lon, float(expected["lat_deg"])]
		assert_almost_eq(float(got["wind_east_m_s"]), float(expected["wind_east_m_s"]), 1e-3, "wind east " + where)
		assert_almost_eq(float(got["wind_north_m_s"]), float(expected["wind_north_m_s"]), 1e-3, "wind north " + where)
		assert_almost_eq(float(got["pressure_pa"]), float(expected["pressure_pa"]), 0.5, "pressure " + where)
		assert_almost_eq(float(got["dust_tau"]), float(expected["dust_tau"]), 1e-4, "dust " + where)
		assert_almost_eq(float(got["temperature_k"]), float(expected["temperature_k"]), 1e-3, "temperature " + where)
	weather.feed([])
	assert_eq(weather.systems(null).size(), 0, "without the service, no system: the climate's mean winds")


func test_an_answer_that_is_not_the_service_s_gives_no_system() -> void:
	assert_eq(WeatherService.states_of("").size(), 0)
	assert_eq(WeatherService.states_of("<html>502</html>").size(), 0)
	assert_eq(WeatherService.states_of("{\"systems\": 3}").size(), 0)


func test_the_systems_horizon_parents_to_the_planet_are_read() -> void:
	var planet := Planet.new()
	add_child_autofree(planet)
	var system := WeatherSystem.new()
	planet.add_child(system)
	system.position = HEALPix.lonlat2vec(-39.5, 20.0) * 6356000.0
	system.apply_prop_data({"kind": "dust_storm", "radius_m": 600000.0, "intensity": 1.0, "pressure_anomaly_pa": -900.0,
			"params": {"wind_peak_ms": 25.0, "dust_tau": 5.0}})
	var elsewhere := WeatherSystem.new()  # another body's system
	add_child_autofree(elsewhere)
	var weather := ClimateWeather.for_body("tarsis_3").duplicate() as ClimateWeather
	var live := weather.systems(planet)
	assert_eq(live.size(), 1, "the planet's own systems only")
	assert_eq(live[0]["kind"], &"dust_storm")
	assert_almost_eq(float(live[0]["lon"]), -39.5, 1e-6)
	assert_gt(float(weather.sample_at(-39.5, 20.0, 0.0, 0.0, 0.0, live)["dust_tau"]), 1.0, "its dust is in the sample")
	assert_eq(float(weather.sample_at(-39.5, 20.0, 0.0, 0.0, 0.0, [])["dust_tau"]), 0.0)


func test_the_air_alone_is_the_sample_s_air() -> void:
	# What the devils and the walls ask (WeatherSampler.air, kept by ClimateWeather.air_at) is the sample's band,
	# wind and dust to the bit, on and off the service's systems, near them and far from them.
	var recorded: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/data/weather/sandbox_service_answers.json"))
	var weather := ClimateWeather.for_body("tarsis_3").duplicate() as ClimateWeather
	weather.feed(WeatherService.states_of(str(recorded["systems_answer"])))
	var live := weather.systems(null)
	var counted := 0
	for k in 400:
		var lon := -180.0 + fposmod(k * 47.3, 360.0)
		var lat := -80.0 + fposmod(k * 13.7, 160.0)
		var whole := weather.sample_at(lon, lat, 0.0, 5.0, 30.0, live)
		counted += (whole["systems"] as Array).size()
		for air: Dictionary in [WeatherSampler.air(weather.profile, live, lon, lat), weather.air_at(lon, lat, live),
				weather.air_at(lon, lat, live)]:
			for key: String in ["band", "wind_east_m_s", "wind_north_m_s", "wind_speed_m_s", "dust_tau"]:
				assert_eq(air[key], whole[key], "%s at lon %.1f lat %.1f" % [key, lon, lat])
	assert_gt(counted, 50, "systems weigh at many of the places")
