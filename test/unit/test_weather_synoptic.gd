extends GutTest
## WeatherSynoptic against the weather service: its hash's golden vectors (hash.rs) and the 24 systems the
## service computed for Sandbox at one instant (test/data/weather/sandbox_samples.json).

const GOLDEN := "res://test/data/weather/sandbox_samples.json"


func test_the_hash_returns_the_service_s_golden_vectors() -> void:
	assert_eq(WeatherSynoptic.splitmix(0), -2152535657050944081, "0xE220A8397B1DCDAF")
	assert_eq(WeatherSynoptic.mix(1, 2, 3, 4), 3843851030613099023, "0x35581A259136820F")
	assert_eq(WeatherSynoptic.mix(42, -7, 1000000, 0), 6878403392881805925, "0x5F74FF71468FCA65")
	assert_eq(WeatherSynoptic.mix(20261006, 0, 0, 0), -5049862998450018844, "0xB9EB485BB4FF65E4")
	assert_almost_eq(WeatherSynoptic.unit(WeatherSynoptic.mix(1, 2, 3, 4)), 0.208376, 1e-6)
	assert_almost_eq(WeatherSynoptic.unit(WeatherSynoptic.mix(20261006, 0, 0, 0)), 0.726246, 1e-6)


func test_the_service_s_systems_are_reproduced() -> void:
	var golden: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN))
	var weather := ClimateWeather.for_body("tarsis_3")
	var got := WeatherSynoptic.systems_at(weather, float(golden["t"]), float(golden["declination_deg"]))
	var expected: Array = golden["systems"]
	assert_eq(got.size(), expected.size(), "as many systems alive")
	for i in mini(got.size(), expected.size()):
		var g: Dictionary = got[i]
		var e: Dictionary = expected[i]
		var which := "system %d (%s)" % [i, e["kind"]]
		assert_eq(String(g["kind"]), String(e["kind"]), "kind of " + which)
		assert_almost_eq(float(g["lon"]), float(e["centre_lon_deg"]), 1e-6, "longitude of " + which)
		assert_almost_eq(float(g["lat"]), float(e["centre_lat_deg"]), 1e-6, "latitude of " + which)
		assert_almost_eq(float(g["sigma_m"]), float(e["sigma_m"]), 1e-3, "size of " + which)
		assert_almost_eq(float(g["intensity"]), float(e["intensity"]), 1e-9, "intensity of " + which)
		assert_almost_eq(float(g["pressure_anomaly_pa"]), float(e["pressure_anomaly_pa"]), 1e-6, "pressure of " + which)
		assert_almost_eq(float(g["wind_peak"]), float(e["wind_peak_m_s"]), 1e-9, "wind of " + which)
		assert_almost_eq(float(g["dust_tau"]), float(e["dust_tau"]), 1e-9, "dust of " + which)


func test_the_weather_hook_gives_the_service_s_samples() -> void:
	var golden: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN))
	var weather := ClimateWeather.for_body("tarsis_3")
	for entry: Dictionary in golden["samples"]:
		var expected: Dictionary = entry["sample"]
		var got := weather.sample_at(float(entry["lon"]), float(entry["lat"]), float(entry["alt"]), float(golden["t"]),
				float(golden["declination_deg"]), float(golden["substellar_lon_deg"]))
		var where := "at lon %.1f lat %.1f" % [float(entry["lon"]), float(entry["lat"])]
		assert_almost_eq(float(got["wind_east_m_s"]), float(expected["wind_east_m_s"]), 1e-3, "wind east " + where)
		assert_almost_eq(float(got["wind_north_m_s"]), float(expected["wind_north_m_s"]), 1e-3, "wind north " + where)
		assert_almost_eq(float(got["pressure_pa"]), float(expected["pressure_pa"]), 0.5, "pressure " + where)
		assert_almost_eq(float(got["dust_tau"]), float(expected["dust_tau"]), 1e-4, "dust " + where)
		assert_almost_eq(float(got["temperature_k"]), float(expected["temperature_k"]), 1e-3, "temperature " + where)
