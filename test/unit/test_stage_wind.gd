extends GutTest
## StageWind, the menu stage's blow: a compass bearing and a speed become the (east, north) parts the
## weather override carries to every presenter.


func test_a_wind_from_the_north_blows_south() -> void:
	var parts : Vector2 = StageWind.wind_parts(10.0, 0.0)
	assert_almost_eq(parts.x, 0.0, 1e-9, "no east part")
	assert_almost_eq(parts.y, -10.0, 1e-9, "toward the south")


func test_a_wind_from_the_east_blows_west_and_keeps_its_speed() -> void:
	var parts : Vector2 = StageWind.wind_parts(8.0, 90.0)
	assert_almost_eq(parts.x, -8.0, 1e-9, "toward the west")
	assert_almost_eq(parts.y, 0.0, 1e-9)
	assert_almost_eq(StageWind.wind_parts(8.0, 225.0).length(), 8.0, 1e-9, "the speed is the speed whatever the bearing")
	assert_almost_eq(WeatherSampler.wind_from_deg(parts.x, parts.y), 90.0, 1e-9, "the sampler reads it back as from the east")
