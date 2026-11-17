extends GutTest
## CloudPlanetMap: the equirectangular map the cloud layer reads the planet's colour from. Its texels
## stand where PlanetData.direction_to_uv puts them (the shader reads it with that convention), a row
## holds the dust albedo of the ground's colour, and the build runs on a worker, handing the texture
## over only once complete.


func test_a_texel_stands_where_the_planet_data_uv_puts_it() -> void:
	for ij: Vector2i in [Vector2i(0, 0), Vector2i(512, 256), Vector2i(1023, 511), Vector2i(300, 70)]:
		var dir: Vector3 = CloudPlanetMap.direction_of(ij.x, ij.y)
		assert_almost_eq(dir.length(), 1.0, 1e-9, "a unit direction")
		var uv: Vector2 = PlanetData.direction_to_uv(dir)
		assert_almost_eq(uv.x * CloudPlanetMap.WIDTH, ij.x + 0.5, 1e-3, "the texel's centre in u")
		assert_almost_eq(uv.y * CloudPlanetMap.HEIGHT, ij.y + 0.5, 1e-3, "the texel's centre in v")
	assert_gt(CloudPlanetMap.direction_of(512, 0).y, 0.99, "the first row: the north pole")
	assert_almost_eq(CloudPlanetMap.direction_of(0, 256).x, -1.0, 1e-2, "u = 0: longitude -180")


func test_a_row_holds_the_dust_albedo() -> void:
	var texels := PackedFloat32Array()
	texels.resize(CloudPlanetMap.WIDTH * CloudPlanetMap.HEIGHT * 3)
	var colour: Callable = func(_dir: Vector3) -> Color: return Color(0.6, 0.45, 0.3)
	CloudPlanetMap.build_row(texels, 256, colour)
	var k: int = (256 * CloudPlanetMap.WIDTH + 100) * 3
	assert_almost_eq(texels[k], WeatherSky.BLOW_ALBEDO_MAX, 1e-5, "the brightest channel at the dust's ceiling")
	assert_almost_eq(texels[k + 1], WeatherSky.BLOW_ALBEDO_MAX * 0.75, 1e-4, "the ground's hue kept")
	assert_almost_eq(texels[k + 2], WeatherSky.BLOW_ALBEDO_MAX * 0.5, 1e-4)
	assert_eq(texels[(255 * CloudPlanetMap.WIDTH) * 3], 0.0, "other rows untouched")


func test_the_build_runs_on_a_worker_and_hands_over_a_complete_map() -> void:
	var map := CloudPlanetMap.new()
	var colour: Callable = func(_dir: Vector3) -> Color: return Color(0.5, 1.0, 0.25)
	assert_false(map.update(colour), "the first call starts the job")
	var polls: int = 0
	while not map.update(colour) and polls < 20000:
		assert_false(map.ready)
		assert_null(map.texture, "nothing handed over before the map is complete")
		OS.delay_msec(1)
		polls += 1
	assert_true(map.ready, "done within 20 s")
	assert_eq(map.texture.get_size(), Vector2(CloudPlanetMap.WIDTH, CloudPlanetMap.HEIGHT))
	assert_almost_eq(map.texture.get_image().get_pixel(10, 10).g, WeatherSky.BLOW_ALBEDO_MAX, 1e-4, "a dust albedo")
	assert_almost_eq(map.texture.get_image().get_pixel(10, 10).r, WeatherSky.BLOW_ALBEDO_MAX * 0.5, 1e-4, "the hue kept")
	assert_false(map.update(colour), "complete: nothing more to do")


func test_a_map_freed_mid_job_waits_for_it() -> void:
	var map := CloudPlanetMap.new()
	# A second of work: a short sleep every 512th texel (a sleep under a millisecond is a millisecond on
	# Windows, so one per texel would be nine minutes).
	var calls: Array = [0]
	var slow: Callable = func(_dir: Vector3) -> Color:
		calls[0] += 1
		if calls[0] % 512 == 0:
			OS.delay_usec(5)
		return Color.WHITE
	map.update(slow)
	assert_true(map._task >= 0, "a job is running")
	map = null  # freed mid-job: it must wait, not leave the worker writing into freed memory
	assert_null(map, "still standing")
