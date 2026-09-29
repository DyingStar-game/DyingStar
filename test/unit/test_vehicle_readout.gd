extends GutTest
## VehicleReadout: the "slope you are on" reading, and the acceleration / 0-100 measurement.
##
## Four lines of trigonometry, and exactly the kind that reads plausibly while being wrong: a
## flipped sign shows a climb as a descent on every hill, and nothing else in the game would
## contradict it. So the convention is pinned here rather than trusted.

const UP := Vector3.UP


func test_flat_ground_reads_zero() -> void:
	assert_almost_eq(VehicleReadout.pitch_deg(Vector3.FORWARD, UP), 0.0, 0.001,
			"driving along the horizontal is no slope at all")


func test_climbing_is_positive() -> void:
	# Nose up 30 degrees: forward has a component along the local vertical.
	var forward := Vector3(0.0, sin(deg_to_rad(30.0)), -cos(deg_to_rad(30.0)))
	assert_almost_eq(VehicleReadout.pitch_deg(forward, UP), 30.0, 0.01,
			"climbing reads positive, and reads the real angle")


func test_descending_is_negative() -> void:
	var forward := Vector3(0.0, -sin(deg_to_rad(15.0)), -cos(deg_to_rad(15.0)))
	assert_almost_eq(VehicleReadout.pitch_deg(forward, UP), -15.0, 0.01,
			"pointing downhill reads negative")


func test_traversing_a_slope_sideways_reads_zero() -> void:
	# The vehicle is tilted (rolled) but driving along the contour: nothing opposes the drive, so
	# the number that matters is zero. Measuring overall TILT instead would report the roll here.
	var up := Vector3(sin(deg_to_rad(20.0)), cos(deg_to_rad(20.0)), 0.0)
	assert_almost_eq(VehicleReadout.pitch_deg(Vector3.FORWARD, up), 0.0, 0.001,
			"driving across a slope costs no tractive force")


func test_a_degenerate_vector_reads_zero_rather_than_nan() -> void:
	assert_eq(VehicleReadout.pitch_deg(Vector3.ZERO, UP), 0.0, "no forward direction, no slope")
	assert_eq(VehicleReadout.pitch_deg(Vector3.FORWARD, Vector3.ZERO), 0.0, "no vertical, no slope")


func test_acceleration_is_measured_over_the_window() -> void:
	var readout := VehicleReadout.new()
	# 0 -> 36 km/h (10 m/s) in 1 s, sampled at 60 Hz: 10 m/s².
	for i in 61:
		readout.measure(1.0 / 60.0, 36.0 * i / 60.0)
	assert_almost_eq(readout.acceleration(), 10.0, 0.5, "10 m/s² over the half-second window")
	assert_gt(readout.peak_acceleration(), 9.0, "and the peak follows")


func test_the_0_100_stopwatch() -> void:
	var readout := VehicleReadout.new()
	readout.measure(0.1, 0.0)  # standing: armed
	for i in 50:
		readout.measure(0.1, 2.0 * (i + 1))  # +20 km/h per second
	assert_almost_eq(readout.sprint_time(), 5.0, 0.11, "100 km/h reached after 5 s")
	readout.measure(0.1, 0.0)
	assert_eq(readout.sprint_time(), 0.0, "a standstill arms the next run")
