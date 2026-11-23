extends GutTest
## WeatherHash against the weather service's golden vectors (hash.rs).


func test_the_hash_returns_the_service_s_golden_vectors() -> void:
	assert_eq(WeatherHash.splitmix(0), -2152535657050944081, "0xE220A8397B1DCDAF")
	assert_eq(WeatherHash.mix(1, 2, 3, 4), 3843851030613099023, "0x35581A259136820F")
	assert_eq(WeatherHash.mix(42, -7, 1000000, 0), 6878403392881805925, "0x5F74FF71468FCA65")
	assert_eq(WeatherHash.mix(20261006, 0, 0, 0), -5049862998450018844, "0xB9EB485BB4FF65E4")
	assert_almost_eq(WeatherHash.unit(WeatherHash.mix(1, 2, 3, 4)), 0.208376, 1e-6)
	assert_almost_eq(WeatherHash.unit(WeatherHash.mix(20261006, 0, 0, 0)), 0.726246, 1e-6)
