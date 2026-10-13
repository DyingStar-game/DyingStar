extends GutTest
## Close over a body with nothing selected, the chart's view turns with the body, as it does for a
## selected place: under 6 500 km the planet's spin slid the ground out from under the camera.

const TARSIS := {"spin_hours": 25.0, "tilt_deg": 15.0}


func test_the_view_rides_the_ground_only_close_and_with_nothing_followed() -> void:
	assert_true(StarMap.follows_ground(5000.0, false), "5 km up, nothing selected: rides the ground")
	assert_true(StarMap.follows_ground(6.0e6, false), "6 000 km up: still riding it")
	assert_false(StarMap.follows_ground(1.0e7, false), "10 000 km up: the planet turns under the view")
	assert_false(StarMap.follows_ground(5000.0, true), "a place selected: that place is what is followed")


func test_the_ground_under_the_camera_stays_under_it() -> void:
	var cam := StarMapCamera.new()
	cam.yaw = 0.7
	cam.pitch = 1.0  # high latitude: where a turn taken off a single point goes wrong
	var t0: float = 1000.0
	var t1: float = t0 + 3600.0
	var spin0: Basis = StarMap._spin_basis(TARSIS, t0)
	var spin1: Basis = StarMap._spin_basis(TARSIS, t1)
	var ground: Vector3 = spin0.inverse() * cam.direction()  # the point under the camera, body-fixed
	cam.turn_by(Quaternion(spin1 * spin0.inverse()))
	assert_almost_eq(cam.direction().distance_to(spin1 * ground), 0.0, 1.0e-5,
			"an hour later the camera is still over the same ground")
