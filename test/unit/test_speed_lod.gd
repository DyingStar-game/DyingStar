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


func test_the_scale_moves_one_step_at_a_time() -> void:
	# 2 000 m/s wants 0.25 at once; going there in one pass replaced all the fine ground at once.
	var t := PlanetTerrain.new()
	t.planet_data = PlanetData.new()
	t._speed_lod_off = 0  # the client.ini switch, not read in a test
	for i in 5:
		t._cam_history.append(Vector3(0, 0, -2000.0 * PlanetTerrain.UPDATE_INTERVAL * i))
	t._update_speed_lod()
	assert_eq(t._speed_lod_scale, 0.5, "one step first")
	t._update_speed_lod()
	assert_eq(t._speed_lod_scale, 0.5, "the next waits SPEED_LOD_STEP_MS")
	t._speed_lod_changed_at -= PlanetTerrain.SPEED_LOD_STEP_MS
	t._update_speed_lod()
	assert_eq(t._speed_lod_scale, 0.25)
	t.free()
