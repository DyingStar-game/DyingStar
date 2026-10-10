extends GutTest
## WeatherAudio, the weather's loops: a layer's gain over its window of a parameter (silent outside,
## full on the plateau, straight ramps at the edges), the storm index that lets one loop carry both a
## gale and a dust storm, and the library's default layer.


func test_a_layers_gain_over_its_window() -> void:
	assert_eq(WeatherAudio.gain_for(5.0, 10.0, 20.0, 0.2, 0.2), 0.0, "under the window")
	assert_eq(WeatherAudio.gain_for(25.0, 10.0, 20.0, 0.2, 0.2), 0.0, "over it")
	assert_eq(WeatherAudio.gain_for(15.0, 10.0, 20.0, 0.2, 0.2), 1.0, "the plateau")
	assert_almost_eq(WeatherAudio.gain_for(11.0, 10.0, 20.0, 0.2, 0.2), 0.5, 1e-9, "halfway up the 2-unit rise")
	assert_almost_eq(WeatherAudio.gain_for(19.5, 10.0, 20.0, 0.2, 0.2), 0.25, 1e-9, "a quarter from the top of the fall")
	assert_eq(WeatherAudio.gain_for(10.0, 10.0, 20.0, 0.0, 0.0), 1.0, "a hard edge: full at the edge")
	assert_eq(WeatherAudio.gain_for(10.0, 10.0, 20.0, 0.5, 0.0), 0.0, "a fade: silent at the edge")
	assert_eq(WeatherAudio.gain_for(15.0, 20.0, 10.0, 0.2, 0.2), 0.0, "an empty window is silent")


func test_the_storm_index_is_the_larger_of_wind_and_dust() -> void:
	assert_eq(WeatherAudio.storm_index({}), 0.0)
	assert_almost_eq(WeatherAudio.storm_index({"wind_speed_m_s": 12.5, "dust_tau": 0.0}), 0.5, 1e-9, "half a gale")
	assert_almost_eq(WeatherAudio.storm_index({"wind_speed_m_s": 0.0, "dust_tau": 1.0}), 0.5, 1e-9, "half the dust")
	assert_almost_eq(WeatherAudio.storm_index({"wind_speed_m_s": 5.0, "dust_tau": 1.5}), 0.75, 1e-9, "the dust wins")
	assert_eq(WeatherAudio.storm_index({"wind_speed_m_s": 60.0, "dust_tau": 9.0}), 1.0, "no more than a full storm")


func test_thin_air_carries_less_and_none_carries_nothing() -> void:
	assert_eq(WeatherAudio.air_factor({}), 0.0, "no weather, no air known: silence")
	assert_eq(WeatherAudio.air_factor({"air_density_kg_m3": 0.0}), 0.0, "vacuum")
	assert_almost_eq(WeatherAudio.air_factor({"air_density_kg_m3": 1.265}), 1.0, 1e-9, "Tarsis III at the ground")
	assert_almost_eq(WeatherAudio.air_factor({"air_density_kg_m3": 0.25}), 0.5, 1e-9, "a quarter of the air: half the gain")
	assert_almost_eq(WeatherAudio.air_factor({"air_density_kg_m3": 0.0125}), 0.112, 0.001, "50 km up on Tarsis III: -19 dB")


func test_a_layer_reads_its_own_parameter() -> void:
	var sample := {"wind_speed_m_s": 7.0, "dust_tau": 0.4}
	assert_eq(WeatherAudio.parameter_of(sample, &"wind_speed_m_s"), 7.0)
	assert_eq(WeatherAudio.parameter_of(sample, &"dust_tau"), 0.4)
	assert_almost_eq(WeatherAudio.parameter_of(sample, &"storm"), 7.0 / WeatherAudio.WIND_FULL_MS, 1e-9)
	assert_eq(WeatherAudio.parameter_of(sample, &"rain"), 0.0, "unknown: silent")
	assert_eq(WeatherAudio.parameter_of({}, &"storm"), 0.0, "no weather: silent")


func test_the_default_layer_is_the_strong_wind_loop() -> void:
	var layers : Array[WeatherAudioLayer] = WeatherAudio.default_layers()
	assert_eq(layers.size(), 1, "the wind loop alone")
	assert_not_null(layers[0].stream, "the CC0 wind loop")
	assert_eq(layers[0].parameter, &"wind_speed_m_s")
	assert_eq(WeatherAudio.gain_for(0.5, layers[0].from, layers[0].to, layers[0].fade_in, layers[0].fade_out), 0.0,
			"a light air: silent")
	assert_almost_eq(WeatherAudio.gain_for(7.0, layers[0].from, layers[0].to, layers[0].fade_in, layers[0].fade_out),
			1.0, 0.03, "a 6-8 m/s wind already at full")
	assert_eq(WeatherAudio.gain_for(25.0, layers[0].from, layers[0].to, layers[0].fade_in, layers[0].fade_out), 1.0,
			"a gale: full")


func test_the_scene_mixes_the_strong_wind_alone() -> void:
	var audio := (load("res://scenes/audio/weather/weather_audio.tscn") as PackedScene).instantiate() as WeatherAudio
	assert_eq(audio.layers.size(), 1, "one loop")
	assert_eq(audio.layers[0].parameter, &"wind_speed_m_s")
	audio.free()


func test_a_shelter_closes_the_low_pass_in_octaves() -> void:
	assert_almost_eq(WeatherAudio.cutoff_for(0.0), WeatherAudio.OPEN_CUTOFF_HZ, 1e-6, "open: transparent")
	assert_almost_eq(WeatherAudio.cutoff_for(1.0), WeatherAudio.SHELTERED_CUTOFF_HZ, 1e-6, "walled in: a wall's muffle")
	assert_almost_eq(WeatherAudio.cutoff_for(0.5), sqrt(WeatherAudio.OPEN_CUTOFF_HZ * WeatherAudio.SHELTERED_CUTOFF_HZ),
			1e-3, "halfway, in octaves")
	assert_almost_eq(WeatherAudio.cutoff_for(7.0), WeatherAudio.SHELTERED_CUTOFF_HZ, 1e-6, "clamped")
