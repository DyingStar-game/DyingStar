extends GutTest
## WeatherSky: the wind's dust layer near the ground. Its density follows what the wind lifts (and a
## storm's dust, when a weather source brings one), its colour the ground's, and it belongs to an eye
## on or near the ground.


func test_the_layer_follows_the_lift_and_takes_the_grounds_colour() -> void:
	assert_eq(WeatherSky.blow_extinction(0.0), 0.0, "no lift: no dust")
	var full: float = WeatherSky.blow_extinction(1.0)
	assert_almost_eq(full, 3.912 / WeatherSky.BLOW_VISIBILITY_FULL_M, 1e-9, "a full blow: 400 m of visibility")
	assert_almost_eq(WeatherSky.blow_extinction(0.5) / full, pow(0.5, WeatherSky.BLOW_POWER), 1e-9, "rises as lift^1.5")
	assert_almost_eq(WeatherSky.blow_extinction(3.0), full, 1e-9, "capped at the full blow")
	var ochre: Vector3 = WeatherSky.blow_albedo_of(Color(0.8, 0.6, 0.4))
	assert_almost_eq(ochre.x, WeatherSky.BLOW_ALBEDO_MAX, 1e-9, "the brightest channel at the cap")
	assert_almost_eq(ochre.y / ochre.x, 0.75, 1e-6, "the ground's own hue kept (Color is float32)")
	assert_almost_eq(ochre.z / ochre.x, 0.5, 1e-6)
	assert_eq(WeatherSky.blow_albedo_of(Color.BLACK), WeatherSky.blow_albedo_of(WeatherSky.BLOW_FALLBACK_COLOUR),
			"no colour: the plains' ochre")


func test_a_storm_adds_its_dust_to_the_lift() -> void:
	assert_eq(WeatherSky.density_for(0.0, 0.0), 0.0, "calm, clear air: no layer")
	assert_almost_eq(WeatherSky.density_for(0.0, 1.0), 1.0 / WeatherSky.STORM_COLUMN_M, 1e-12, "a storm alone")
	assert_almost_eq(WeatherSky.density_for(1.0, 1.0), WeatherSky.blow_extinction(1.0) + 1.0 / WeatherSky.STORM_COLUMN_M,
			1e-12, "both add")
	assert_eq(WeatherSky.density_for(0.0, -1.0), 0.0, "a negative depth is no dust")


func test_the_default_wind_raises_dust() -> void:
	var weather: UniformWeather = Planet.DEFAULT_WEATHER as UniformWeather
	var lifted: float = DustLift.ground_lift(weather.wind_speed_m_s, weather.lift_threshold_m_s)
	assert_gt(WeatherSky.density_for(lifted, 0.0), 0.0, "the default wind is over the threshold: the layer shows")


func test_the_near_layer_is_for_an_eye_near_the_ground() -> void:
	assert_eq(WeatherSky.near_layer_share(-400.0), 0.0, "under the terrain (god mode): none")
	assert_eq(WeatherSky.near_layer_share(1.7), 1.0, "standing: all of it")
	assert_eq(WeatherSky.near_layer_share(WeatherSky.NEAR_LAYER_FULL_M), 1.0, "low flight: all of it")
	assert_eq(WeatherSky.near_layer_share(WeatherSky.NEAR_LAYER_GONE_M), 0.0, "high in EVA: none")


func test_the_far_dust_lies_on_a_ground_grid_that_reaches_it() -> void:
	assert_true(DustGround.half_m(WeatherSky.FAR_CELL_M) >= WeatherSky.FAR_RANGE_M,
			"the far dust never runs past the ground it lies on")
	var far := DustGround.new(WeatherSky.FAR_CELL_M, WeatherSky.FAR_REBUILD_M)
	assert_eq(far.half(), DustGround.half_m(WeatherSky.FAR_CELL_M), "the grid knows its own size")
	assert_eq(DustGround.new().half(), DustGround.half_m(), "the near grid keeps its cells")


func test_the_noise_offset_wraps_to_its_period() -> void:
	var v: Vector3 = WeatherSky.wrap_to_period(Vector3(-10.0, 230.0, 110.0), 110.0)
	assert_almost_eq(v, Vector3(100.0, 10.0, 0.0), Vector3.ONE * 1e-9, "always in [0, period)")
