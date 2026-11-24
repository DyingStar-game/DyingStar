extends GutTest
## The weather phenomena's noise is made on a worker (WeatherPhenomena.noise_images) instead of by NoiseTexture2D /
## NoiseTexture3D, which make their first image on the main thread at once: 2.5 s in the frame the player's planet
## arrived. It must be the noise those textures made.

const PHENOMENA := preload("res://scenes/planet/weather/weather_phenomena.gd")


func _grain() -> FastNoiseLite:
	var grain := FastNoiseLite.new()
	grain.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	grain.frequency = 0.012
	grain.fractal_octaves = 4
	return grain


func _cells() -> FastNoiseLite:
	var cells := FastNoiseLite.new()
	cells.noise_type = FastNoiseLite.TYPE_CELLULAR
	cells.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	cells.frequency = 0.07
	cells.fractal_octaves = 3
	return cells


func test_the_grain_is_what_a_noise_texture_made() -> void:
	var texture := NoiseTexture2D.new()
	texture.noise = _grain()
	texture.seamless = true
	texture.width = 256
	texture.height = 256
	await wait_frames(3)  # a NoiseTexture2D makes its first image at the end of the frame
	var made: Image = PHENOMENA.noise_images(_grain(), _cells())[0]
	var theirs := texture.get_image()
	assert_not_null(theirs, "the texture made its image")
	assert_eq(made.get_size(), theirs.get_size())
	assert_eq(made.get_format(), theirs.get_format())
	assert_eq(made.has_mipmaps(), theirs.has_mipmaps(), "its mipmaps too")
	assert_true(made.get_data() == theirs.get_data(), "the same bytes")


func test_the_billows_are_a_cube_of_the_wall_noise_size() -> void:
	# A NoiseTexture3D's layers cannot be read back headless (the dummy renderer keeps none); compared to the bit
	# with a renderer on 2026-11-24. Here: their shape.
	var layers: Array = PHENOMENA.noise_images(_grain(), _cells())[1]
	assert_eq(layers.size(), PHENOMENA.WALL_NOISE_SIZE)
	for layer: Image in [layers[0], layers[layers.size() - 1]]:
		assert_eq(layer.get_size(), Vector2i(PHENOMENA.WALL_NOISE_SIZE, PHENOMENA.WALL_NOISE_SIZE))
		assert_eq(layer.get_format(), Image.FORMAT_L8)


func test_the_dust_gusts_are_a_cube_of_noise_texels() -> void:
	# WeatherSky's gusts, made on a worker for the same reason (2.4 s as the player appeared); compared to the bit
	# with a NoiseTexture3D's under a renderer on 2026-11-24.
	var layers: Array = WeatherSky.gust_layers()
	assert_eq(layers.size(), WeatherSky.NOISE_TEXELS)
	assert_eq((layers[0] as Image).get_size(), Vector2i(WeatherSky.NOISE_TEXELS, WeatherSky.NOISE_TEXELS))
	assert_eq((layers[0] as Image).get_format(), Image.FORMAT_L8)
