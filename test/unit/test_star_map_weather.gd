extends GutTest
## StarMapWeather, the chart's weather layer: a texel of its field grid IS the sampler's answer at the
## cell's centre (the chart and the physics read one truth), its arrows stand on the shell and point
## with the wind, its hours are the service's, and it fades out as the zoom reaches the ground.

const PROFILE := "res://scenes/planet/climates/tarsis_3.tres"

var _profile : ClimateProfile = null
## Two systems, as WeatherSystem.state() reports them: a deep low and a dust storm.
var _systems : Array = []


func before_all() -> void:
	_profile = load(PROFILE)
	_systems = [
		_system(1, &"depression", 10.0, 20.0, 600000.0, 0.8, -1500.0, 25.0, 0.0),
		_system(2, &"dust_storm", -60.0, -10.0, 400000.0, 1.0, -800.0, 30.0, 3.0),
	]


static func _system(id: int, kind: StringName, lon: float, lat: float, sigma_m: float, intensity: float,
		anomaly_pa: float, wind_peak: float, dust_tau: float) -> Dictionary:
	return {
		"id": id, "name": "", "kind": kind, "lon": lon, "lat": lat, "sigma_m": sigma_m,
		"intensity": intensity, "pressure_anomaly_pa": anomaly_pa, "wind_peak": wind_peak,
		"dust_tau": dust_tau, "precipitation_mm_h": 0.0, "humidity": 0.0,
	}


func test_a_texel_is_the_sample_at_its_cell_centre() -> void:
	var built : Dictionary = StarMapWeather.build_fields(_profile, _systems, 30.0, 5.0, 36, 18)
	var image : Image = built["image"]
	assert_eq(image.get_size(), Vector2i(36, 18))
	# Cell (10, 4) of a 10° grid: longitude -180 + 10.5 × 10, latitude 90 - 4.5 × 10.
	var lon : float = -75.0
	var lat : float = 45.0
	var expected : Dictionary = WeatherSampler.sample(_profile, _systems, lon, lat, 0.0,
			StarMapWeather.local_hours(30.0, lon), 5.0)
	var texel : Color = image.get_pixel(10, 4)
	assert_almost_eq(texel.r, float(expected["pressure_anomaly_pa"]), 1e-3, "r = pressure anomaly")
	assert_almost_eq(texel.g, float(expected["dust_tau"]), 1e-5, "g = dust")
	assert_almost_eq(texel.a, float(expected["wind_speed_m_s"]), 1e-4, "a = wind speed")
	# Inside the storm the dust shows and the pressure is low.
	var storm : Color = image.get_pixel(12, 10)  # lon -55, lat -15
	assert_gt(storm.g, 0.3, "dust under the storm (a cell off its centre)")
	assert_lt(storm.r, -100.0, "low pressure under the storm")


func test_one_arrow_cell_in_nine_carries_the_wind() -> void:
	var built : Dictionary = StarMapWeather.build_fields(_profile, _systems, 0.0, 0.0, 36, 18)
	var arrows : PackedFloat32Array = built["arrows"]
	assert_eq(arrows.size(), 12 * 6 * 4, "36 × 18 cells, one in three each way, four numbers each")
	# The first arrow cell is (1, 1): longitude -180 + 1.5 × 10, latitude 90 - 1.5 × 10.
	assert_almost_eq(arrows[0], -165.0, 1e-4)
	assert_almost_eq(arrows[1], 75.0, 1e-4)


func test_an_arrow_stands_on_the_shell_and_points_with_the_wind() -> void:
	var lon : float = -75.0
	var lat : float = 45.0
	var xf : Transform3D = StarMapWeather.arrow_transform(lon, lat, 10.0, 0.0, 0.5, 0.06)
	assert_almost_eq(xf.origin.length(), 0.5, 1e-9, "on the shell")
	var axes : Array = WeatherSampler.local_axes(lon, lat)
	var forward : Vector3 = -xf.basis.z.normalized()
	assert_almost_eq(forward.dot(axes[0]), 1.0, 1e-6, "-Z along the wind: due east here")
	assert_almost_eq(xf.basis.y.normalized().dot(xf.origin.normalized()), 1.0, 1e-6, "+Y radial")
	assert_almost_eq(xf.basis.z.length(), 0.06 * StarMapWeather.ARROW_FILL * (10.0 / StarMapWeather.ARROW_MAX_MS),
			1e-9, "a third of the full length for a third of the wind")
	var gale : Transform3D = StarMapWeather.arrow_transform(lon, lat, 0.0, 60.0, 0.5, 0.06)
	assert_almost_eq(gale.basis.z.length(), 0.06 * StarMapWeather.ARROW_FILL, 1e-9, "capped at the full length")
	assert_almost_eq((-gale.basis.z.normalized()).dot(axes[1]), 1.0, 1e-6, "due north")


func test_the_local_hour_is_the_services() -> void:
	assert_almost_eq(StarMapWeather.local_hours(0.0, 0.0), 12.0, 1e-9, "noon under the star")
	assert_almost_eq(StarMapWeather.local_hours(0.0, 90.0), 6.0, 1e-9)
	assert_almost_eq(StarMapWeather.local_hours(0.0, -90.0), 18.0, 1e-9)
	assert_almost_eq(StarMapWeather.local_hours(180.0, -180.0), 12.0, 1e-9, "wraps")


func test_the_layer_fades_out_as_the_zoom_reaches_the_ground() -> void:
	assert_eq(StarMapWeather.strength(500.0), 0.0, "500 m per pixel: the ground's chart")
	assert_eq(StarMapWeather.strength(10000.0), 1.0, "10 km per pixel: the sky's")
	var between : float = StarMapWeather.strength(2750.0)
	assert_between(between, 0.3, 0.7)
