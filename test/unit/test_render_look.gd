extends GutTest

## The game's look of the frame (AtmosphereRenderer.apply_look): the AgX tone mapper the team chose, the
## exposure and the colour adjustment after it.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_render_look.gd


func test_the_look_is_agx_with_its_adjustment() -> void:
	var env := Environment.new()
	AtmosphereRenderer.apply_look(env)
	assert_eq(env.tonemap_mode, Environment.TONE_MAPPER_AGX, "the team's tone mapper")
	assert_almost_eq(env.tonemap_exposure, AtmosphereRenderer.LOOK_EXPOSURE, 1e-6, "stored as a 32-bit float")
	assert_true(env.adjustment_enabled, "saturation and contrast only apply with the adjustment on")
	assert_almost_eq(env.adjustment_saturation, AtmosphereRenderer.LOOK_SATURATION, 1e-6)
	assert_almost_eq(env.adjustment_contrast, AtmosphereRenderer.LOOK_CONTRAST, 1e-6)
