extends GutTest
## WeatherSampler is the twin of the weather service's sampler (weather-core/src/sampler.rs): fed
## the same climate, the same systems and the same point, it must return the same numbers. The
## service exports golden samples (`WEATHER_EXPORT=1 cargo test --test export_derived`), copied to
## test/data/weather/sandbox_samples.json — a divergence would raise no error anywhere, it would
## push the truck with a wind the client does not draw.

const GOLDEN := "res://test/data/weather/sandbox_samples.json"
const PROFILE := "res://scenes/planet/climates/tarsis_3.tres"

var _golden : Dictionary = {}
var _profile : ClimateProfile = null


func before_all() -> void:
	_golden = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN))
	_profile = load(PROFILE)


## The service's SystemState → the Dictionary a WeatherSystem node reports.
static func _system_from_golden(s: Dictionary) -> Dictionary:
	return {
		"id": int(s["id"]),
		"name": "",
		"kind": StringName(String(s["kind"])),
		"lon": float(s["centre_lon_deg"]),
		"lat": float(s["centre_lat_deg"]),
		"sigma_m": float(s["sigma_m"]),
		"intensity": float(s["intensity"]),
		"pressure_anomaly_pa": float(s["pressure_anomaly_pa"]),
		"wind_peak": float(s["wind_peak_m_s"]),
		"dust_tau": float(s["dust_tau"]),
		"precipitation_mm_h": float(s["precipitation_mm_h"]),
		"humidity": float(s["humidity"]),
	}


func test_the_golden_file_and_the_profile_are_there() -> void:
	assert_false(_golden.is_empty(), "golden samples parsed")
	assert_not_null(_profile, "tarsis_3 climate profile generated")
	assert_true(_profile.has_atmosphere)


func test_every_golden_sample_is_reproduced() -> void:
	var systems : Array = []
	for s in _golden["systems"]:
		systems.append(_system_from_golden(s))
	var decl : float = float(_golden["declination_deg"])
	var sub_lon : float = float(_golden["substellar_lon_deg"])
	for entry in _golden["samples"]:
		var expected : Dictionary = entry["sample"]
		var lon : float = float(entry["lon"])
		var lat : float = float(entry["lat"])
		var alt : float = float(entry["alt"])
		var hours : float = fposmod((sub_lon - lon) / 360.0 * 24.0 + 12.0, 24.0)
		var got : Dictionary = WeatherSampler.sample(_profile, systems, lon, lat, alt, hours, decl)
		var where : String = "at lon %.1f lat %.1f" % [lon, lat]
		assert_almost_eq(got["wind_east_m_s"], float(expected["wind_east_m_s"]), 1e-3, "wind east " + where)
		assert_almost_eq(got["wind_north_m_s"], float(expected["wind_north_m_s"]), 1e-3, "wind north " + where)
		assert_almost_eq(got["wind_from_deg"], float(expected["wind_from_deg"]), 0.05, "wind from " + where)
		assert_almost_eq(got["pressure_pa"], float(expected["pressure_pa"]), 0.5, "pressure " + where)
		assert_almost_eq(got["dust_tau"], float(expected["dust_tau"]), 1e-4, "dust " + where)
		assert_almost_eq(got["temperature_k"], float(expected["temperature_k"]), 0.05, "temperature " + where)
		assert_almost_eq(got["air_density_kg_m3"], float(expected["air_density_kg_m3"]), 1e-4, "air density " + where)
		assert_eq(String(got["band"]), String(expected["band"]), "band " + where)


func test_the_trades_blow_toward_the_equator_and_the_westerlies_away() -> void:
	var north : Dictionary = WeatherSampler.band_wind(_profile, 15.0)
	assert_eq(north["band"], WeatherSampler.BAND_TRADES)
	assert_lt(north["east"], 0.0, "from the east")
	assert_lt(north["north"], 0.0, "toward the equator (south)")
	var south : Dictionary = WeatherSampler.band_wind(_profile, -15.0)
	assert_gt(south["north"], 0.0, "toward the equator (north)")
	var mid : Dictionary = WeatherSampler.band_wind(_profile, 45.0)
	assert_eq(mid["band"], WeatherSampler.BAND_WESTERLIES)
	assert_gt(mid["east"], 0.0, "from the west")


func test_wind_from_follows_the_meteorological_convention() -> void:
	assert_almost_eq(WeatherSampler.wind_from_deg(0.0, -1.0), 0.0, 1e-9, "blowing south comes from the north")
	assert_almost_eq(WeatherSampler.wind_from_deg(-1.0, 0.0), 90.0, 1e-9, "blowing west comes from the east")
	assert_almost_eq(WeatherSampler.wind_from_deg(1.0, 0.0), 270.0, 1e-9, "blowing east comes from the west")


func test_a_low_turns_counter_clockwise_north_of_the_equator() -> void:
	var low := {"id": 1, "name": "", "kind": WeatherSampler.KIND_DEPRESSION, "lon": 10.0, "lat": 45.0,
		"sigma_m": 300000.0, "intensity": 1.0, "pressure_anomaly_pa": -2000.0, "wind_peak": 20.0,
		"dust_tau": 0.0, "precipitation_mm_h": 0.0, "humidity": 0.0}
	# East of the centre is the direction of DEcreasing longitude.
	var east_point_lon : float = 10.0 - rad_to_deg(300000.0 / (_profile.radius_m * cos(deg_to_rad(45.0))))
	var k : Dictionary = WeatherSampler.contribution(_profile, low, east_point_lon, 45.0)
	assert_gt(k["north"], 0.0, "east of a northern low the wind blows north: %s" % str(k))
	assert_almost_eq(k["weight"], exp(-0.5), 1e-3, "about one sigma away (great circle vs flat offset)")
	var centre : Dictionary = WeatherSampler.contribution(_profile, low, 10.0, 45.0)
	assert_almost_eq(centre["east"], 0.0, 1e-9, "calm eye")
