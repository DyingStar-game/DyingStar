extends GutTest
## VehicleDust.rate: how hard a driven tyre stirs the ground — rolling, spinning, and what the ground
## has to give.


func test_a_standing_vehicle_raises_nothing() -> void:
	assert_eq(VehicleDust.rate(0.0, 0.0, 1.0, 40.0), 0.0)


func test_the_dust_grows_with_the_speed_then_holds() -> void:
	var slow: float = VehicleDust.rate(10.0, 10.0, 1.0, 40.0)
	var fast: float = VehicleDust.rate(30.0, 30.0, 1.0, 40.0)
	assert_gt(fast, slow)
	assert_eq(VehicleDust.rate(40.0, 40.0, 1.0, 40.0), VehicleDust.rate(90.0, 90.0, 1.0, 40.0),
			"full past dust_full_kmh")


func test_a_spinning_wheel_digs_more_than_a_rolling_one() -> void:
	assert_gt(VehicleDust.rate(5.0, 30.0, 1.0, 40.0), VehicleDust.rate(5.0, 5.0, 1.0, 40.0))
	assert_gt(VehicleDust.rate(0.0, 30.0, 1.0, 40.0), 0.0, "spinning on the spot still throws dust")


func test_reverse_raises_dust_like_forward() -> void:
	assert_eq(VehicleDust.rate(-20.0, -20.0, 1.0, 40.0), VehicleDust.rate(20.0, 20.0, 1.0, 40.0))


func test_the_ground_decides_how_much_there_is() -> void:
	assert_gt(VehicleDust.rate(30.0, 30.0, 1.0, 40.0), VehicleDust.rate(30.0, 30.0, 0.15, 40.0))
	assert_eq(VehicleDust.rate(30.0, 60.0, 0.0, 40.0), 0.0, "metal: nothing, spinning or not")


## The ground's share counts once. puff() applies it (DustEmitter), so the tyres hand it a stir that
## leaves the ground out — rate() at amount 1. Counted twice, rock and corundum raised no visible dust.
func test_the_tyres_stir_leaves_the_ground_to_the_puff() -> void:
	var stir: float = VehicleDust.rate(30.0, 30.0, 1.0, 40.0)
	var on_corundum: float = VehicleDust.rate(30.0, 30.0, 0.4, 40.0)
	assert_almost_eq(on_corundum, stir * 0.4, 1e-6, "the ground scales the stir once")


## The trail is laid by distance: a puff per PUFF_SPACING_M rolled, whatever the speed — timed puffs
## left gaps at speed, a coughing "pot pot pot".
func test_the_trail_is_laid_by_distance_not_by_time() -> void:
	var spacing := VehicleDust.PUFF_SPACING_M
	assert_almost_eq(VehicleDust.puffs_owed(spacing * 3.0, 0.0, 0.016), 3.0, 1e-6, "one per spacing")
	assert_almost_eq(VehicleDust.puffs_owed(spacing * 3.0, 0.0, 0.1), 3.0, 1e-6, "the frame time does not count")
	assert_eq(VehicleDust.puffs_owed(0.0, 0.0, 0.5), 0.0, "standing still: nothing")
	assert_gt(VehicleDust.puffs_owed(0.0, 1.0, 0.5), 0.0, "spinning in place still digs")
