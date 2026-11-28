extends GutTest
## NoiseVolume: a seamless 3D noise made on a worker, never on the main thread -- the images a seamless
## NoiseTexture3D would make (Noise.get_seamless_image_3d, its 0.1 skirt), handed to whoever waits, at once
## once they exist.


func _noise() -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.frequency = 0.09
	return noise


func test_the_texture_comes_to_whoever_waits() -> void:
	var noise := _noise()
	var volume := NoiseVolume.new(noise, Vector3i(16, 8, 4), true, true)
	assert_null(volume.texture(), "not at once: made on a worker")
	var got: Array = []
	volume.when_ready(func(tex: Texture3D) -> void: got.append(tex))
	for k in 120:
		if not got.is_empty():
			break
		await get_tree().process_frame
	assert_eq(got.size(), 1, "the callback ran once")
	var tex := got[0] as ImageTexture3D
	assert_eq([tex.get_width(), tex.get_height(), tex.get_depth()], [16, 8, 4])
	var later: Array = []
	volume.when_ready(func(t: Texture3D) -> void: later.append(t))
	assert_eq(later.size(), 1, "made already: called at once")


func test_its_images_are_the_noise_s_seamless_ones() -> void:
	var noise := _noise()
	var volume := NoiseVolume.new(noise, Vector3i(8, 8, 8), false, true)
	while volume.texture() == null:
		await get_tree().process_frame
	var want: Array = noise.get_seamless_image_3d(8, 8, 8, false, 0.1, true)
	var have: Array = volume.get("_images")  # its own images: a headless texture keeps no data
	assert_eq(have.size(), want.size())
	if have.size() == want.size():
		assert_eq((have[3] as Image).get_data(), (want[3] as Image).get_data(), "the same voxels")
