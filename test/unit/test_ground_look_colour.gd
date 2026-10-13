extends GutTest
## GroundLook: what a textured ground SHOWS (its texture's mean times the tint its shader applies) and
## what the fringe paints with (that tint, applied by the fringe shader with the ground's own strength).
## The fringe once showed the bare texture, white marble on every corundum plateau, and the dust off
## those plateaus took a colour darker than the ground (2026-10-11).

const CORUNDUM_SURFACE := "res://assets/_universe/_shared/materials/mat_mineral_corundum_pure/corundum_outcrop_surface.tres"


func test_the_shown_colour_is_the_mean_times_the_tint_by_its_strength() -> void:
	var mean := Color(0.8, 0.8, 0.8)
	var tint := Color(1.0, 0.5, 0.25)
	var full: Color = GroundLook.shown_colour(mean, tint, 1.0)
	assert_almost_eq(full.r, 0.8, 1e-6)
	assert_almost_eq(full.g, 0.4, 1e-6, "tinted all the way")
	assert_almost_eq(full.b, 0.2, 1e-6)
	var none: Color = GroundLook.shown_colour(mean, tint, 0.0)
	assert_almost_eq(none.g, 0.8, 1e-6, "no tint: the texture's own mean")
	var half: Color = GroundLook.shown_colour(mean, tint, 0.5)
	assert_almost_eq(half.g, 0.8 * 0.75, 1e-6, "half the tint")


func test_the_mean_of_a_texture_is_its_average_colour() -> void:
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(1.0, 0.0, 0.0))
	img.set_pixel(1, 0, Color(0.0, 1.0, 0.0))
	img.set_pixel(0, 1, Color(0.0, 0.0, 1.0))
	img.set_pixel(1, 1, Color(1.0, 1.0, 1.0))
	var mean: Color = GroundLook._mean_of(ImageTexture.create_from_image(img))
	assert_almost_eq(mean.r, 0.5, 0.02)
	assert_almost_eq(mean.g, 0.5, 0.02)
	assert_almost_eq(mean.b, 0.5, 0.02)
	assert_eq(mean.a, 1.0)


func test_the_fringe_on_corundum_applies_the_grounds_tint_strength() -> void:
	var ground := load(CORUNDUM_SURFACE) as ShaderMaterial
	assert_not_null(ground, "the corundum ground material must load")
	var fringe: ShaderMaterial = GroundLook.material_for(ground)
	assert_not_null(fringe)
	assert_true(bool(fringe.get_shader_parameter(&"blend_use_albedo")), "the textured path")
	assert_almost_eq(float(fringe.get_shader_parameter(&"blend_vertex_color_strength")),
			float(ground.get_shader_parameter(&"vertex_color_strength")), 1e-6,
			"the fringe tints its texture as much as the ground does: no more white band")


func test_the_fringe_tint_is_the_terrains_own_vertex_colour() -> void:
	# The terrain's own rule (the roads use it too), not RockCatalogue's bare mottle: two buildings on the
	# same plateau took a pale and a rust-red fringe from it (2026-10-12).
	var data := PlanetData.new()
	data.planet_name = "testgroundlook"
	data.radius = 6356000.0
	data.export_nside = 64
	data.corundum_default_biome = true
	data.warm_biome_cache()
	var d := Vector3(0.6, 0.48, -0.64).normalized()
	var cor_bd: BiomeDefinition = data.get_biome_by_type(ArideDesertCorundumPlateauTerrain.BIOME_TYPE)
	assert_eq(GroundLook.vertex_colour(data, d, Color.MAGENTA),
			PlanetChunk.road_ground_tint(data, d, {}, cor_bd), "the colour the ground vertices get")
