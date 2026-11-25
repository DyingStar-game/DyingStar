extends GutTest
## The star map's weather layer: the grid it samples, the isobars traced through it, the highs and lows
## found in it, where the arrows stand at a zoom, and what the cursor readout writes.

const Grid := preload("res://scenes/ui/star_map/star_map_weather_grid.gd")
const Layer := preload("res://scenes/ui/star_map/star_map_weather.gd")

## The readout's formats in English, standing for the translation server.
const FORMATS: Dictionary = {
	"%%HUD_MAP_WEATHER_WIND": "Wind %s km/h from %s",
	"%%HUD_MAP_WEATHER_CALM": "Calm",
	"%%HUD_MAP_WEATHER_PRESSURE": "%s hPa (%s)",
	"%%HUD_MAP_WEATHER_TEMPERATURE": "T %s °C",
	"%%HUD_MAP_WEATHER_DUST": "dust %s",
	"%%COMPASS_N": "N", "%%COMPASS_E": "E", "%%COMPASS_S": "S", "%%COMPASS_W": "W",
}


func _english(key: String) -> String:
	return FORMATS.get(key, key)


## A pressure field (Pa) with a low of -20 hPa round (lon 30, lat 20) and a high of +16 hPa round
## (lon -100, lat -30), both about 1 500 km wide on a body like Sandbox.
static func _two_centres(lon: float, lat: float) -> float:
	var low: float = HEALPix.lonlat2vec(lon, lat).angle_to(HEALPix.lonlat2vec(30.0, 20.0))
	var high: float = HEALPix.lonlat2vec(lon, lat).angle_to(HEALPix.lonlat2vec(-100.0, -30.0))
	return 101300.0 - 2000.0 * exp(-pow(low / 0.25, 2.0)) + 1600.0 * exp(-pow(high / 0.25, 2.0))


func test_cells_are_centred_from_the_top_left() -> void:
	assert_almost_eq(Grid.cell_lon(0, 90), -178.0, 1e-6)
	assert_almost_eq(Grid.cell_lon(89, 90), 178.0, 1e-6)
	assert_almost_eq(Grid.cell_lat(0, 45), 88.0, 1e-6)
	assert_almost_eq(Grid.cell_lat(44, 45), -88.0, 1e-6)


func test_the_grid_asks_the_source_once_per_cell() -> void:
	var asked: Array = [0]
	var grid: Dictionary = Grid.sample_grid(func(lon: float, lat: float) -> Dictionary:
		asked[0] += 1
		return {"pressure_pa": lon + 1000.0 * lat, "wind_east_m_s": 3.0, "wind_north_m_s": -lat}, 8, 4)
	assert_eq(asked[0], 32)
	assert_true(grid["has_pressure"])
	assert_almost_eq(float(grid["pressure"][0]), Grid.cell_lon(0, 8) + 1000.0 * Grid.cell_lat(0, 4), 0.01)
	assert_almost_eq(float(grid["north"][3 * 8]), -Grid.cell_lat(3, 4), 1e-4)
	var calm: Dictionary = Grid.sample_grid(func(_lon: float, _lat: float) -> Dictionary: return {}, 4, 2)
	assert_false(calm["has_pressure"], "a source that gives no pressure draws no isobar")


func test_bilinear_is_exact_on_a_cell_and_wraps_the_longitude() -> void:
	var values := PackedFloat32Array([0.0, 10.0, 20.0, 30.0, 100.0, 110.0, 120.0, 130.0])  # 4 x 2
	assert_almost_eq(Grid.bilinear(values, 4, 2, Grid.cell_lon(1, 4), Grid.cell_lat(0, 2)), 10.0, 1e-4)
	# Half way between the last column (30) and the first (0), across the seam.
	assert_almost_eq(Grid.bilinear(values, 4, 2, 180.0, Grid.cell_lat(0, 2)), 15.0, 1e-4)
	assert_almost_eq(Grid.bilinear(values, 4, 2, Grid.cell_lon(2, 4), 0.0), 70.0, 1e-4)


func test_upsampling_keeps_a_constant_and_a_slope() -> void:
	var w: int = 12
	var h: int = 6
	var flat := PackedFloat32Array()
	var slope := PackedFloat32Array()
	for y in h:
		for x in w:
			flat.append(500.0)
			slope.append(10.0 * float(y))
	var fine_flat: PackedFloat32Array = Grid.upsample(flat, w, h, 3)
	var fine_slope: PackedFloat32Array = Grid.upsample(slope, w, h, 3)
	assert_eq(fine_flat.size(), w * h * 9)
	for v in fine_flat:
		assert_almost_eq(v, 500.0, 1e-3)
	# Row 7 of the fine grid has its centre on coarse row 2 (7.5 / 3 - 0.5): 20, wherever along it.
	assert_almost_eq(fine_slope[7 * w * 3 + 5], 20.0, 1e-3)
	assert_almost_eq(fine_slope[8 * w * 3 + 30], 20.0 + 10.0 / 3.0, 1e-3)


func test_isobars_ring_a_low_on_their_levels() -> void:
	var grid: Dictionary = Grid.sample_grid(func(lon: float, lat: float) -> Dictionary:
		return {"pressure_pa": _two_centres(lon, lat)}, Grid.COARSE_W, Grid.COARSE_H)
	var values: PackedFloat32Array = grid["pressure"]
	var lines: PackedVector2Array = Grid.isobars(values, Grid.COARSE_W, Grid.COARSE_H, Grid.ISOBAR_PA)
	assert_gt(lines.size(), 40, "a low of 20 hPa and a high of 16 draw rings")
	assert_eq(lines.size() % 2, 0, "segments come in pairs of points")
	for p: Vector2 in lines:
		var level: float = Grid.bilinear(values, Grid.COARSE_W, Grid.COARSE_H, p.x, p.y)
		var off: float = absf(level - roundf(level / Grid.ISOBAR_PA) * Grid.ISOBAR_PA)
		assert_lt(off, 1.0, "every point of an isobar lies on a multiple of 2 hPa")
	# The innermost ring (-18 hPa) stays close to the low's centre.
	var near: int = 0
	for p: Vector2 in lines:
		if HEALPix.lonlat2vec(p.x, p.y).angle_to(HEALPix.lonlat2vec(30.0, 20.0)) < 0.5:
			near += 1
	assert_gt(near, 10)


func test_a_flat_field_has_no_isobar() -> void:
	var flat := PackedFloat32Array()
	flat.resize(20 * 10)
	flat.fill(100250.0)
	assert_eq(Grid.isobars(flat, 20, 10, Grid.ISOBAR_PA).size(), 0)


func test_a_saddle_gives_two_segments_per_cell() -> void:
	# 2 x 2, the longitude wrapping: both cells are saddles (high corners facing each other).
	var values := PackedFloat32Array([100.0, -100.0, -100.0, 100.0])
	assert_eq(Grid.isobars(values, 2, 2, 150.0).size(), 2 * 2 * 2, "one level (0), two segments in each of the two cells")


func test_the_highs_and_lows_are_found_where_they_are() -> void:
	var grid: Dictionary = Grid.sample_grid(func(lon: float, lat: float) -> Dictionary:
		return {"pressure_pa": _two_centres(lon, lat)}, Grid.COARSE_W, Grid.COARSE_H)
	var found: Array[Dictionary] = Grid.extrema(grid["pressure"], Grid.COARSE_W, Grid.COARSE_H)
	assert_eq(found.size(), 2, str(found))
	for c: Dictionary in found:
		var target: Vector3 = HEALPix.lonlat2vec(-100.0, -30.0) if c["high"] else HEALPix.lonlat2vec(30.0, 20.0)
		assert_lt(HEALPix.lonlat2vec(c["lon"], c["lat"]).angle_to(target), deg_to_rad(4.0), str(c))
	var flat := PackedFloat32Array()
	flat.resize(Grid.COARSE_W * Grid.COARSE_H)
	flat.fill(101300.0)
	assert_eq(Grid.extrema(flat, Grid.COARSE_W, Grid.COARSE_H).size(), 0, "a flat field has no centre")


func test_the_arrows_close_up_as_the_zoom_goes_in() -> void:
	var radius: float = 6356000.0
	assert_eq(Grid.arrow_step_deg(1.0e6, radius), Grid.ARROW_BASE_DEG, "the whole globe: the widest step")
	var mid: float = Grid.arrow_step_deg(2000.0, radius)
	var close: float = Grid.arrow_step_deg(50.0, radius)
	assert_lt(close, mid)
	# About ARROW_PX pixels apart: within a factor two of it.
	var px: float = deg_to_rad(mid) * radius / 2000.0
	assert_between(px, Grid.ARROW_PX, Grid.ARROW_PX * 2.0)


func test_the_lattice_stands_on_the_step_and_stays_bounded() -> void:
	var step: float = 2.0
	var points: PackedVector2Array = Grid.arrow_lattice(-40.5, 25.2, step)
	assert_lte(points.size(), (Grid.ARROW_HALF * 2 + 1) * (Grid.ARROW_HALF * 2 + 1))
	var has_centre: bool = false
	for p: Vector2 in points:
		assert_almost_eq(fposmod(p.y, step), 0.0, 1e-6, "rows on multiples of the step")
		assert_lt(absf(p.y), 90.0)
		if p.distance_to(Vector2(-40.0, 26.0)) < 1e-6:
			has_centre = true
	assert_true(has_centre, "the lattice point nearest the view's centre is there")
	var globe: PackedVector2Array = Grid.arrow_lattice(0.0, 0.0, Grid.ARROW_BASE_DEG)
	var equator: int = 0
	for p: Vector2 in globe:
		if p.y == 0.0:
			equator += 1
	assert_eq(equator, int(360.0 / Grid.ARROW_BASE_DEG), "the whole circle, once round")


func test_the_eight_winds() -> void:
	assert_eq(Grid.compass(0.0, "N", "E", "S", "O"), "N")
	assert_eq(Grid.compass(44.0, "N", "E", "S", "O"), "NE")
	assert_eq(Grid.compass(225.0, "N", "E", "S", "O"), "SO")
	assert_eq(Grid.compass(350.0, "N", "E", "S", "O"), "N")


func test_the_readout_says_wind_pressure_temperature_dust() -> void:
	var sample: Dictionary = {"wind_speed_m_s": 25.0, "wind_from_deg": 45.0, "pressure_pa": 101800.0,
		"pressure_anomaly_pa": -200.0, "temperature_k": 287.15, "dust_tau": 0.04}
	assert_eq(Grid.readout_text(sample, _english),
			"Wind 90 km/h from NE   1018 hPa (-2)   T 14 °C   dust 0.0")
	assert_eq(Grid.readout_text({"wind_east_m_s": 0.0, "wind_north_m_s": 0.1}, _english), "Calm",
			"a source that gives only a light wind")
	assert_eq(Grid.readout_text({}, _english), "", "no air, nothing to say")


func test_an_arrow_points_down_the_wind_along_the_ground() -> void:
	var xf: Transform3D = Layer.arrow_transform(30.0, 20.0, 10.0, 0.0, 0.5, 0.01)
	var up: Vector3 = HEALPix.lonlat2vec(30.0, 20.0)
	var east: Vector3 = Planet.local_axes(up)[0]
	assert_almost_eq((-xf.basis.z).normalized().dot(east), 1.0, 1e-4, "an east wind's arrow points east")
	assert_almost_eq(xf.origin.distance_to(up * 0.5), 0.0, 1e-6)
	var gale: Transform3D = Layer.arrow_transform(30.0, 20.0, 60.0, 0.0, 0.5, 0.01)
	assert_gt(gale.basis.z.length(), xf.basis.z.length(), "a stronger wind, a longer arrow")


## The layer's whole sampling on Tarsis 3's real climate, as the worker runs it: a pressure, winds, and
## isobars when the climate has any relief of pressure (a system makes some, whatever the climate's).
func test_the_layer_samples_tarsis_3_as_the_game_does() -> void:
	var weather: ClimateWeather = ClimateWeather.for_body("tarsis_3")
	if weather == null or weather.profile == null:
		pass_test("no climate for tarsis_3 in this tree")
		return
	var live: Array = [{"id": "test-low", "name": "Test low", "kind": WeatherSampler.KIND_DEPRESSION, "lon": 20.0, "lat": 35.0,
		"sigma_m": 600000.0, "intensity": 1.0, "pressure_anomaly_pa": -1500.0, "wind_peak": 20.0,
		"dust_tau": 0.0, "precipitation_mm_h": 0.0, "humidity": 0.3}]
	var sampler := func(lon: float, lat: float) -> Dictionary:
		return weather.sample_at(lon, lat, 0.0, 0.0, 0.0, live)
	var started: int = Time.get_ticks_msec()
	var built: Dictionary = Layer._build(sampler, false)
	gut.p("star map weather grid: %d ms" % (Time.get_ticks_msec() - started))
	var grid: Dictionary = built["grid"]
	assert_true(grid["has_pressure"])
	var strongest: float = 0.0
	var east: PackedFloat32Array = grid["east"]
	for v in east:
		strongest = maxf(strongest, absf(v))
	assert_gt(strongest, 1.0, "the climate's bands blow somewhere")
	assert_gt((built["lines"] as PackedVector2Array).size(), 0, "the low draws isobars")
