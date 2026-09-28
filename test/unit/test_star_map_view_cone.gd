extends GutTest
## StarMapViewCone: the heading drawn on the chart is the way you face ON THE GROUND.


func test_looking_down_a_slope_still_points_ahead() -> void:
	var up := Vector3.UP
	var forward := Vector3(0.0, -0.6, -0.8)  # looking down at the ground in front
	var flat := StarMapViewCone.level_forward(forward, up)
	assert_almost_eq(flat.dot(up), 0.0, 1e-6, "level")
	assert_almost_eq(flat.dot(Vector3.FORWARD), 1.0, 1e-6, "still ahead")


func test_the_level_is_the_players_not_the_worlds() -> void:
	var up := Vector3(1.0, 0.0, 0.0)  # a station floor turned on its side, say
	var flat := StarMapViewCone.level_forward(Vector3(0.7, 0.0, -0.7), up)
	assert_almost_eq(flat.dot(up), 0.0, 1e-6, "no part along the player's up")
	assert_almost_eq(flat.length(), 1.0, 1e-6, "a direction")


func test_straight_up_has_no_heading() -> void:
	assert_eq(StarMapViewCone.level_forward(Vector3.UP, Vector3.UP), Vector3.ZERO, "nothing to show")

