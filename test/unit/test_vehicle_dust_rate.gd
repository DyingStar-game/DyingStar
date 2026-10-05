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
