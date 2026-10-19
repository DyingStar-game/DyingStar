extends GutTest
## VehicleTyreSound: the tyres' rolling noise grows with the speed, by a few decibels per doubling, and
## rises in pitch, both settling at the top speed.


func test_the_top_speed_is_the_configured_level() -> void:
	assert_almost_eq(VehicleTyreSound.roll_db(80.0, 5.0, 80.0, 4.0), 0.0, 0.001)
	assert_almost_eq(VehicleTyreSound.roll_db(130.0, 5.0, 80.0, 4.0), 0.0, 0.001, "held past the top")


func test_each_halving_of_the_speed_loses_the_same_decibels() -> void:
	assert_almost_eq(VehicleTyreSound.roll_db(40.0, 5.0, 80.0, 4.0), -4.0, 0.001)
	assert_almost_eq(VehicleTyreSound.roll_db(20.0, 5.0, 80.0, 4.0), -8.0, 0.001)
	assert_almost_eq(VehicleTyreSound.roll_db(10.0, 5.0, 80.0, 4.0), -12.0, 0.001)


func test_below_the_fade_in_speed_the_level_stops_falling() -> void:
	# Under low_kmh the loop's own fade-in from standstill takes over: no double attenuation.
	assert_almost_eq(VehicleTyreSound.roll_db(1.0, 5.0, 80.0, 4.0), VehicleTyreSound.roll_db(5.0, 5.0, 80.0, 4.0), 0.001)


func test_reverse_sounds_like_forward() -> void:
	assert_eq(VehicleTyreSound.roll_db(-30.0, 5.0, 80.0, 4.0), VehicleTyreSound.roll_db(30.0, 5.0, 80.0, 4.0))
	assert_eq(VehicleTyreSound.roll_pitch(-30.0, 5.0, 80.0, 0.85, 1.15), VehicleTyreSound.roll_pitch(30.0, 5.0, 80.0, 0.85, 1.15))


func test_the_pitch_rises_with_the_speed_then_holds() -> void:
	assert_almost_eq(VehicleTyreSound.roll_pitch(5.0, 5.0, 80.0, 0.85, 1.15), 0.85, 0.001)
	assert_almost_eq(VehicleTyreSound.roll_pitch(42.5, 5.0, 80.0, 0.85, 1.15), 1.0, 0.001, "half way")
	assert_almost_eq(VehicleTyreSound.roll_pitch(80.0, 5.0, 80.0, 0.85, 1.15), 1.15, 0.001)
	assert_almost_eq(VehicleTyreSound.roll_pitch(120.0, 5.0, 80.0, 0.85, 1.15), 1.15, 0.001, "held past the top")
	assert_almost_eq(VehicleTyreSound.roll_pitch(0.0, 5.0, 80.0, 0.85, 1.15), 0.85, 0.001, "pulling away")


func test_the_cap_follows_the_level_so_the_driver_hears_the_curve() -> void:
	# max_db caps volume + distance gain: left at the top level, the driver (inside the falloff) heard
	# every speed at full.
	var vehicle := Vehicle.new()
	var player := AudioStreamPlayer3D.new()
	player.max_db = -9.5
	vehicle._drive_tyre_loop(player, 0.4, 0.4, 0.25, 0.08, -25.0, 1.0 / 60.0)
	assert_almost_eq(player.volume_db, -25.0 + linear_to_db(0.4), 0.001)
	assert_almost_eq(player.max_db, player.volume_db, 0.001)
	player.free()
	vehicle.free()
