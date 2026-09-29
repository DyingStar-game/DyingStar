extends GutTest
## Graphics > View distance / Vegetation distance on PlanetTerrain: the ground near the camera keeps
## full detail whatever the option, the scaling is continuous, and a decoration's draw range is
## rescaled from its original band rather than compounded.

const NEAR : float = PlanetTerrain.VIEW_DISTANCE_NEAR_M


func test_the_ground_near_the_camera_is_never_scaled() -> void:
	for mult in [0.5, 1.0, 2.0]:
		assert_almost_eq(PlanetTerrain._view_scaled(NEAR * 0.5, mult), NEAR * 0.5, 0.001, "x%s near" % mult)
		assert_almost_eq(PlanetTerrain._view_scaled(NEAR, mult), NEAR, 0.001, "x%s at the edge" % mult)


func test_beyond_it_the_option_stretches_or_compresses() -> void:
	var far : float = NEAR + 1000.0
	assert_almost_eq(PlanetTerrain._view_scaled(far, 1.0), far, 0.001, "x1 changes nothing")
	assert_almost_eq(PlanetTerrain._view_scaled(far, 2.0), NEAR + 500.0, 0.001, "x2: seen as closer, finer")
	assert_almost_eq(PlanetTerrain._view_scaled(far, 0.5), NEAR + 2000.0, 0.001, "x0.5: seen as further, coarser")


func test_a_draw_range_rescales_from_its_band() -> void:
	var grass := MultiMeshInstance3D.new()
	autofree(grass)
	PlanetTerrain._set_draw_range(grass, 10.0, 400.0, 1.5)
	assert_almost_eq(grass.visibility_range_end, 600.0, 0.001, "scaled at build")
	PlanetTerrain._scale_draw_range(grass, 0.5)
	assert_almost_eq(grass.visibility_range_begin, 5.0, 0.001, "begin rescaled from the band")
	assert_almost_eq(grass.visibility_range_end, 200.0, 0.001, "end rescaled from the band, not from 600")


func test_a_missing_decoration_is_ignored() -> void:
	PlanetTerrain._scale_draw_range(null, 2.0)
	assert_true(true, "no error on a chunk without that decoration")
