extends GutTest
## Fast flight coarsens the terrain (PlanetTerrain.speed_lod_scale): a step at its speed, left
## only below SPEED_LOD_EXIT of it.


func test_a_truck_keeps_full_detail() -> void:
	assert_eq(PlanetTerrain.speed_lod_scale(35.0, 1.0), 1.0)


func test_fast_flight_drops_one_level_then_two() -> void:
	assert_eq(PlanetTerrain.speed_lod_scale(150.0, 1.0), 0.5)
	assert_eq(PlanetTerrain.speed_lod_scale(499.0, 0.5), 0.5)
	assert_eq(PlanetTerrain.speed_lod_scale(500.0, 0.5), 0.25)
	assert_eq(PlanetTerrain.speed_lod_scale(900.0, 1.0), 0.25)


func test_a_step_held_is_left_only_well_below_its_speed() -> void:
	# 130 m/s: not enough to enter the first step, enough to stay in it.
	assert_eq(PlanetTerrain.speed_lod_scale(130.0, 1.0), 1.0)
	assert_eq(PlanetTerrain.speed_lod_scale(130.0, 0.5), 0.5)
	assert_eq(PlanetTerrain.speed_lod_scale(110.0, 0.5), 1.0)
	assert_eq(PlanetTerrain.speed_lod_scale(450.0, 0.25), 0.25)
	assert_eq(PlanetTerrain.speed_lod_scale(390.0, 0.25), 0.5)

