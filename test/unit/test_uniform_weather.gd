extends GutTest
## The weather a planet has without a service: UniformWeather, the same wind everywhere, each place
## along its own east / north (Planet.local_axes), behind the WeatherSource door every consumer uses.


func test_a_west_wind_blows_east() -> void:
	var parts: Vector2 = UniformWeather.wind_parts(12.0, 270.0)
	assert_almost_eq(parts, Vector2(12.0, 0.0), Vector2.ONE * 1e-9, "from the west: toward the east")
	assert_almost_eq(UniformWeather.wind_parts(5.0, 0.0), Vector2(0.0, -5.0), Vector2.ONE * 1e-9, "from the north: south")
	assert_almost_eq(UniformWeather.wind_parts(5.0, 90.0), Vector2(-5.0, 0.0), Vector2.ONE * 1e-9, "from the east: west")


func test_the_sample_carries_the_whole_contract() -> void:
	var weather := UniformWeather.new()
	weather.wind_speed_m_s = 8.0
	weather.wind_from_deg = 270.0
	var s: Dictionary = weather.sample(null, Vector3.RIGHT)
	for key: String in ["wind_east_m_s", "wind_north_m_s", "wind_speed_m_s", "wind_from_deg", "dust_tau",
			"lift_threshold_m_s"]:
		assert_true(s.has(key), "key %s" % key)
	assert_almost_eq(float(s["wind_east_m_s"]), 8.0, 1e-9)
	assert_eq(float(s["dust_tau"]), 0.0, "clear air")
	assert_eq(WeatherSource.new().sample(null, Vector3.RIGHT), {}, "the base source: calm, clear air")


## Its numbers are game design, tuned in uniform_weather.tres: only checked to be a usable wind.
func test_the_default_is_a_uniform_wind() -> void:
	var weather: UniformWeather = Planet.DEFAULT_WEATHER as UniformWeather
	assert_not_null(weather, "the planets' default weather is a UniformWeather")
	assert_between(weather.wind_speed_m_s, 0.0, 60.0, "a wind, not a hurricane")
	assert_between(weather.wind_from_deg, 0.0, 360.0, "a bearing")
	assert_gt(weather.lift_threshold_m_s, 0.0, "the ground has a threshold")


func test_the_local_axes_follow_the_longitude_convention() -> void:
	# lon = atan2(-z, x): at lon 0 / lat 0 (+X), east is -Z (growing longitude) and north is +Y.
	var axes: Array = Planet.local_axes(Vector3.RIGHT)
	assert_almost_eq(axes[0] as Vector3, Vector3(0.0, 0.0, -1.0), Vector3.ONE * 1e-9, "east")
	assert_almost_eq(axes[1] as Vector3, Vector3.UP, Vector3.ONE * 1e-9, "north")
	var dir := Vector3(0.3, 0.6, -0.5).normalized()
	var other: Array = Planet.local_axes(dir)
	assert_almost_eq((other[0] as Vector3).dot(dir), 0.0, 1e-9, "east lies along the ground")
	assert_almost_eq((other[1] as Vector3).dot(dir), 0.0, 1e-9, "north lies along the ground")
	assert_almost_eq((other[0] as Vector3).dot(other[1] as Vector3), 0.0, 1e-9, "east and north square")
	assert_gt((other[1] as Vector3).y, 0.0, "north climbs toward the +Y pole")


func test_at_a_pole_the_axes_are_still_defined() -> void:
	var axes: Array = Planet.local_axes(Vector3.UP)
	assert_almost_eq((axes[0] as Vector3).length(), 1.0, 1e-9)
	assert_almost_eq((axes[1] as Vector3).length(), 1.0, 1e-9)
