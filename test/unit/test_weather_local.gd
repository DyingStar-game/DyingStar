extends GutTest
## WeatherLocal, the wind where you stand: in a canyon the part along the trench is channelled and the
## part across is sheltered, faded with how deep you are; the gusts breathe around the mean, bounded,
## continuous over the ground, the same for the same seed, clock and place; apply() keeps the regional
## wind beside the local one.


func test_a_trench_channels_the_wind_along_it_and_shelters_across() -> void:
	var axis := Vector2(1.0, 0.0)  # a trench running east-west
	var along : Vector2 = WeatherLocal.canyon_wind(10.0, 0.0, axis, 1.0)
	assert_almost_eq(along.x, 10.0 * WeatherLocal.CANYON_ALONG_GAIN, 1e-9, "along: channelled")
	assert_almost_eq(along.y, 0.0, 1e-9)
	var across : Vector2 = WeatherLocal.canyon_wind(0.0, 10.0, axis, 1.0)
	assert_almost_eq(across.y, 10.0 * WeatherLocal.CANYON_ACROSS_FACTOR, 1e-9, "across: sheltered")
	var slant : Vector2 = WeatherLocal.canyon_wind(10.0, 10.0, axis, 1.0)
	assert_almost_eq(slant.x, 18.0, 1e-9)
	assert_almost_eq(slant.y, 4.0, 1e-9, "each part on its own")
	var half : Vector2 = WeatherLocal.canyon_wind(10.0, 10.0, axis, 0.5)
	assert_almost_eq(half.x, 14.0, 1e-9, "halfway down: half the gain")
	assert_almost_eq(half.y, 7.0, 1e-9)
	assert_eq(WeatherLocal.canyon_wind(10.0, 10.0, axis, 0.0), Vector2(10.0, 10.0), "on the plateau: untouched")
	assert_eq(WeatherLocal.canyon_wind(10.0, 10.0, Vector2.ZERO, 1.0), Vector2(10.0, 10.0), "no axis known: untouched")
	var tilted : Vector2 = WeatherLocal.canyon_wind(10.0, 0.0, Vector2(2.0, 0.0), 1.0)
	assert_almost_eq(tilted.x, 18.0, 1e-9, "the axis is normalised")


func test_gusts_breathe_around_the_mean_and_never_step() -> void:
	var lo : float = INF
	var hi : float = -INF
	var sum : float = 0.0
	var n : int = 0
	for i in 600:  # ten minutes, every second
		var g : float = WeatherLocal.gust_factor(20261006, 12.345, -8.7, 1.0e9 + float(i))
		lo = minf(lo, g)
		hi = maxf(hi, g)
		sum += g
		n += 1
	assert_gte(lo, 1.0 - WeatherLocal.GUST_SWING - 1e-9, "never under the trough")
	assert_lte(hi, 1.0 + WeatherLocal.GUST_SWING + 1e-9, "never over the peak")
	assert_gt(hi - lo, 0.3, "it does breathe")
	assert_almost_eq(sum / float(n), 1.0, 0.05, "around the mean")
	# Continuity in time and in space: a tenth of a second, or ten metres, change little.
	var a : float = WeatherLocal.gust_factor(20261006, 12.345, -8.7, 1.0e9)
	var b : float = WeatherLocal.gust_factor(20261006, 12.345, -8.7, 1.0e9 + 0.1)
	assert_lt(absf(a - b), 0.12, "a tenth of a second")
	var c : float = WeatherLocal.gust_factor(20261006, 12.345 + 0.0001, -8.7, 1.0e9)
	assert_lt(absf(a - c), 0.02, "ten metres over")
	# Across a cell border too: the blend makes the field continuous.
	var edge : float = 12.0 * WeatherLocal.GUST_CELL_DEG
	var before : float = WeatherLocal.gust_factor(20261006, edge - 1e-6, -8.7, 1.0e9)
	var after : float = WeatherLocal.gust_factor(20261006, edge + 1e-6, -8.7, 1.0e9)
	assert_lt(absf(before - after), 1e-3, "no step at a cell border")


func test_gusts_are_the_same_for_the_same_inputs_and_differ_by_seed() -> void:
	assert_eq(WeatherLocal.gust_factor(1, 0.0, 0.0, 123.0), WeatherLocal.gust_factor(1, 0.0, 0.0, 123.0))
	var differ : bool = false
	for i in 20:
		if absf(WeatherLocal.gust_factor(1, 0.0, 0.0, float(i)) - WeatherLocal.gust_factor(2, 0.0, 0.0, float(i))) > 1e-6:
			differ = true
	assert_true(differ, "another seed, other gusts")


func test_apply_keeps_the_regional_wind_beside_the_local_one() -> void:
	var sample := {"wind_east_m_s": 10.0, "wind_north_m_s": 0.0, "wind_speed_m_s": 10.0, "wind_from_deg": 270.0,
			"dust_tau": 0.2}
	var out : Dictionary = WeatherLocal.apply(sample, {"depth": 1.0, "axis": Vector2(1.0, 0.0)}, 1.2, 45.0)
	assert_almost_eq(out["wind_east_m_s"], 10.0 * WeatherLocal.CANYON_ALONG_GAIN * 1.2, 1e-9, "channelled, then the gust")
	assert_almost_eq(out["wind_speed_m_s"], 21.6, 1e-9)
	assert_eq(out["wind_mean_east_m_s"], 10.0, "the regional wind kept")
	assert_eq(out["wind_mean_speed_m_s"], 10.0)
	assert_eq(out["gust_factor"], 1.2)
	assert_eq(out["canyon_depth"], 1.0)
	assert_eq(out["dust_tau"], 0.2, "the rest of the sample untouched")
	assert_eq(sample["wind_east_m_s"], 10.0, "the input not written to")
	var capped : Dictionary = WeatherLocal.apply(sample, {"depth": 1.0, "axis": Vector2(1.0, 0.0)}, 1.35, 20.0)
	assert_almost_eq(capped["wind_speed_m_s"], 20.0, 1e-9, "the body's ceiling holds")
	var plain : Dictionary = WeatherLocal.apply(sample, {}, 1.0, 45.0)
	assert_almost_eq(plain["wind_east_m_s"], 10.0, 1e-9, "no canyon, no gust: the regional wind")
