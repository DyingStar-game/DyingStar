extends GutTest
## Fast flight coarsens the terrain (PlanetTerrain.speed_lod_scale): a step at its speed, left
## only below SPEED_LOD_EXIT of it.


func test_a_truck_keeps_full_detail() -> void:
	assert_eq(PlanetTerrain.speed_lod_scale(35.0, 1.0), 1.0)


func test_fast_flight_drops_one_level_then_two() -> void:
	assert_eq(PlanetTerrain.speed_lod_scale(999.0, 1.0), 1.0, "ordinary flight keeps full detail")
	assert_eq(PlanetTerrain.speed_lod_scale(1000.0, 1.0), 0.5)
	assert_eq(PlanetTerrain.speed_lod_scale(2999.0, 0.5), 0.5)
	assert_eq(PlanetTerrain.speed_lod_scale(3000.0, 0.5), 0.25)
	assert_eq(PlanetTerrain.speed_lod_scale(5000.0, 1.0), 0.25)


func test_a_step_held_is_left_only_well_below_its_speed() -> void:
	# 900 m/s: not enough to enter the first step, enough to stay in it.
	assert_eq(PlanetTerrain.speed_lod_scale(900.0, 1.0), 1.0)
	assert_eq(PlanetTerrain.speed_lod_scale(900.0, 0.5), 0.5)
	assert_eq(PlanetTerrain.speed_lod_scale(700.0, 0.5), 1.0)
	assert_eq(PlanetTerrain.speed_lod_scale(2500.0, 0.25), 0.25)
	assert_eq(PlanetTerrain.speed_lod_scale(2300.0, 0.25), 0.5)



## A slow frame delays the LOD update: the speed comes from the clock, not from the updates' nominal pace.
func test_a_slow_frame_does_not_inflate_the_speed() -> void:
	var t := PlanetTerrain.new()
	# 800 m/s, sampled every 320 ms: 256 m a sample, which read 1 024 m/s at a nominal 250 ms.
	for i in 5:
		t._cam_history.append(Vector3(256.0 * i, 0.0, 0.0))
		t._cam_history_ms.append(320 * i)
	t._update_speed_lod()
	assert_eq(t._speed_lod_scale, 1.0)
	t.free()
