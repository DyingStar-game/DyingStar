extends GutTest
## VehicleOdometer: the distance a vehicle drives, counted in its parent's frame, and carried over
## the wire (and so into persistence) as "odometer_km".

var _o: VehicleOdometer = null


func before_each() -> void:
	_o = VehicleOdometer.new()


func test_the_first_position_is_only_a_start() -> void:
	_o.track(Vector3(1000, 0, 0), "planet")
	assert_eq(_o.km(), 0.0, "nothing driven yet")


func test_it_adds_up_the_moves() -> void:
	for i in 101:
		_o.track(Vector3(i * 10.0, 0, 0), "planet")
	assert_almost_eq(_o.km(), 1.0, 1e-9, "100 steps of 10 m")


func test_a_teleport_is_not_driving() -> void:
	_o.track(Vector3.ZERO, "planet")
	_o.track(Vector3(5000, 0, 0), "planet")
	assert_eq(_o.km(), 0.0, "5 km in one tick is a reset, not a drive")
	_o.track(Vector3(5010, 0, 0), "planet")
	assert_almost_eq(_o.km(), 0.01, 1e-9, "counting resumes from the new place")


func test_a_new_parent_is_a_new_frame() -> void:
	_o.track(Vector3.ZERO, "planet_a")
	_o.track(Vector3(20, 0, 0), "planet_b")
	assert_eq(_o.km(), 0.0, "positions in two frames do not compare")


func test_it_sends_to_the_hundred_metres_and_only_on_change() -> void:
	_o.track(Vector3.ZERO, "p")
	_o.track(Vector3(40, 0, 0), "p")
	var first: Dictionary = {}
	_o.write_changes(first)
	assert_eq(first, {"odometer_km": 0.0}, "40 m rounds to 0.0 km")
	_o.track(Vector3(80, 0, 0), "p")
	var second: Dictionary = {}
	_o.write_changes(second)
	assert_almost_eq(float(second.get("odometer_km", -1.0)), 0.1, 1e-9, "80 m rounds to 0.1 km")
	var third: Dictionary = {}
	_o.write_changes(third)
	assert_true(third.is_empty(), "nothing new, nothing sent")


func test_a_restored_value_keeps_counting_and_is_not_sent_back() -> void:
	_o.read({"odometer_km": 1234.5})
	assert_almost_eq(_o.km(), 1234.5, 1e-9, "restored from persistence")
	var out: Dictionary = {}
	_o.write_changes(out)
	assert_true(out.is_empty(), "a restore is not news")
	_o.track(Vector3.ZERO, "p")
	_o.track(Vector3(0, 0, 30), "p")
	assert_almost_eq(_o.km(), 1234.53, 1e-9, "and it counts on from there")
