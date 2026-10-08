extends GutTest
## DustLight and SkySlabs: the light through dust (the direct beam by Beer's law, the total by the
## two-stream estimate, never less than the direct), and the sky slabs laid at once on the first
## reading then glided toward the next ones.


func test_clear_air_lets_everything_through() -> void:
	var light: Vector2 = DustLight.split(0.0, 0.5)
	assert_almost_eq(light.x, 1.0, 1e-9, "no dust: the whole beam")
	assert_almost_eq(light.y, 1.0, 1e-9)


func test_a_storm_takes_the_beam_and_gives_most_of_it_back_diffuse() -> void:
	var light: Vector2 = DustLight.split(2.6, 0.5)
	assert_almost_eq(light.x, exp(-2.6 / 0.5), 1e-9, "the direct beam: Beer along the slant")
	assert_almost_eq(light.y, 1.0 / (1.0 + 0.75 * 0.3 * 2.6), 1e-6, "the total: two-stream, ~63 %")
	assert_gt(light.y, light.x, "most of what reaches the ground is diffuse")


func test_a_star_on_the_horizon_gives_a_number() -> void:
	var light: Vector2 = DustLight.split(1.0, 0.0)
	assert_false(is_nan(light.x))
	assert_almost_eq(light.x, exp(-1.0 / 0.02), 1e-12, "the slant floored at 0.02")


func test_the_slabs_are_laid_at_once_then_glide() -> void:
	var renderer := AtmosphereRenderer.new()
	var slabs := SkySlabs.new()
	slabs.blow_beta = 0.01
	slabs.blow_top = 8000.0
	slabs.glide(renderer, 1.0)
	assert_eq(renderer.weather_blow_beta, 0.0, "nothing glides before the first reading is laid")
	slabs.settle(renderer)
	assert_eq(renderer.weather_blow_beta, 0.01, "the first reading: at once")
	assert_eq(renderer.weather_blow_top_m, 8000.0)
	slabs.blow_top = 9000.0
	slabs.settle(renderer)
	assert_eq(renderer.weather_blow_top_m, 8000.0, "later readings never jump")
	slabs.glide(renderer, 0.25)
	assert_almost_eq(renderer.weather_blow_top_m, 8000.0 + 1000.0 * (1.0 - exp(-1.0)), 0.01, "they glide")
	renderer.free()
