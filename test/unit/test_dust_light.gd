extends GutTest
## DustLight: the light through dust (the direct beam by Beer's law, the total by the two-stream
## estimate, never less than the direct), and the star's beam before any dust.


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


func test_the_free_beam_crosses_the_air_but_no_dust() -> void:
	var noon: Vector3 = DustLight.free_beam(Color(1.0, 0.95, 0.9), 2.0, Color.WHITE)
	assert_almost_eq(noon.x, 2.0, 1e-9, "clear air at noon: the star at the engine's energy")
	var dawn: Vector3 = DustLight.free_beam(Color.WHITE, 2.0, Color(0.4, 0.15, 0.05))
	assert_gt(dawn.x, dawn.z * 4.0, "at sunrise the beam is orange and faint, not white")
	var night: Vector3 = DustLight.free_beam(Color.WHITE, 2.0, Color.BLACK)
	assert_eq(night, Vector3.ZERO, "the star under the horizon lights no dust")
