extends GutTest
## MovementProbe: the owner's on-foot stutter probe names each kind of cut, and stays quiet on a smooth walk.

const FRAME_S: float = 1.0 / 60.0
const NET_US: int = 33_000  # a 30 Hz stream


## A smooth walk at 4 m/s: positions every 33 ms, the body drawn at the same pace -> no hitch at all.
func _walk(probe: MovementProbe, seconds: float, from_us: int = 0) -> int:
	var usec: int = from_us
	var next_net: int = from_us
	var t: float = 0.0
	while t < seconds:
		if usec >= next_net:
			probe.on_target(Vector3(4.0 * float(next_net) / 1e6, 0, 0), next_net)
			next_net += NET_US
		probe.on_frame(Vector3(4.0 * float(usec) / 1e6, 0, 0), FRAME_S, true, usec)
		usec += int(FRAME_S * 1e6)
		t += FRAME_S
	return usec


func test_a_smooth_walk_reports_nothing() -> void:
	var probe := MovementProbe.new()
	_walk(probe, 1.5)
	for kind: String in ["net", "jump", "back", "stall", "frame", "snap"]:
		assert_eq(probe.count(kind), 0, "%s: nothing to report on a smooth walk" % kind)


func test_a_late_position_is_a_net_hole() -> void:
	var probe := MovementProbe.new()
	var usec: int = _walk(probe, 1.0)
	probe.on_target(Vector3(4.0 * float(usec + 200_000) / 1e6, 0, 0), usec + 200_000)
	assert_eq(probe.count("net"), 1, "200 ms against a usual 33 ms is a hole in the stream")


func test_a_far_position_is_a_jump() -> void:
	var probe := MovementProbe.new()
	var usec: int = _walk(probe, 1.0)
	probe.on_target(Vector3(10.0, 0, 0), usec)
	assert_eq(probe.count("jump"), 1)


func test_going_back_with_keys_held_is_a_correction() -> void:
	var probe := MovementProbe.new()
	var usec: int = _walk(probe, 1.0)
	# Half a metre behind where the walk is now: behind the last position too, whatever its phase.
	probe.on_target(Vector3(4.0 * float(usec) / 1e6 - 0.5, 0, 0), usec + NET_US)
	probe.on_target(Vector3(0.0, 0, 0), usec + 2 * NET_US)  # far back: a jump, counted once, not twice
	assert_eq(probe.count("back"), 1, "the target went back against the walk")


func test_a_body_drawn_still_mid_walk_is_a_stall() -> void:
	var probe := MovementProbe.new()
	var usec: int = _walk(probe, 1.0)
	var here := Vector3(4.0 * float(usec) / 1e6, 0, 0)
	probe.on_frame(here, FRAME_S, true, usec)
	probe.on_frame(here, FRAME_S, true, usec + 16_000)
	assert_gt(probe.count("stall"), 0)


func test_a_long_frame_and_a_reset_are_named() -> void:
	var probe := MovementProbe.new()
	probe.on_frame(Vector3.ZERO, 0.08, false, 0)
	probe.on_snap(10)
	assert_eq(probe.count("frame"), 1)
	assert_eq(probe.count("snap"), 1)


func test_the_period_line_comes_with_the_hitches() -> void:
	var probe := MovementProbe.new()
	var lines: PackedStringArray = probe.on_frame(Vector3.ZERO, 0.08, false, 0)
	assert_eq(lines.size(), 1, "the frame hitch, printed at once")
	assert_string_starts_with(lines[0], "[MoveHitch]")
	lines = probe.on_frame(Vector3.ZERO, MovementProbe.PERIOD_S, false, 3_000_000)
	assert_string_starts_with(lines[lines.size() - 1], "[MoveProbe]")


## A steady stream every [param gap_us], keys held, one position per frame: the cadence line's input.
func _stream(probe: MovementProbe, gap_us: int, count: int, from_us: int = 0) -> int:
	var usec: int = from_us
	for i: int in count:
		probe.on_frame(Vector3(4.0 * float(usec) / 1e6, 0, 0), FRAME_S, true, usec)
		probe.on_target(Vector3(4.0 * float(usec) / 1e6, 0, 0), usec, i)
		usec += gap_us
	return usec


func test_a_15_hz_stream_reads_15_hz() -> void:
	var probe := MovementProbe.new()
	_stream(probe, 66_667, 25)
	var c: Dictionary = probe.cadence()
	assert_eq(c["n"], 24, "every gap walked through counts")
	assert_almost_eq(float(c["rate_hz"]), 15.0, 0.1)
	assert_almost_eq(float(c["p50"]), 66.7, 0.5)
	assert_almost_eq(float(c["sd"]), 0.0, 0.5, "a steady stream has no spread")
	assert_eq(str(c["hist"]), str([0, 0, 24, 0, 0]), "15 Hz lands in the 45-80 ms bucket")


func test_two_positions_in_one_frame_are_counted() -> void:
	var probe := MovementProbe.new()
	probe.on_frame(Vector3.ZERO, FRAME_S, true, 0)
	probe.on_target(Vector3(0.1, 0, 0), 0, 7)
	probe.on_target(Vector3(0.2, 0, 0), 500, 7)
	assert_eq(probe.cadence()["same_frame"], 1, "the second one waited in the socket")


func test_a_stop_is_a_pause_not_a_slow_stream() -> void:
	var probe := MovementProbe.new()
	var usec: int = _stream(probe, 33_333, 10)
	probe.on_frame(Vector3.ZERO, FRAME_S, false, usec)  # keys released: the server goes quiet
	usec += 2_000_000
	probe.on_frame(Vector3.ZERO, FRAME_S, true, usec)
	probe.on_target(Vector3(10.0, 0, 0), usec, 1000)
	var c: Dictionary = probe.cadence()
	assert_eq(c["pauses"], 1)
	assert_lt(float(c["max"]), 40.0, "the 2 s stop is not in the stream's gaps")
	assert_almost_eq(float(c["rate_hz"]), 30.0, 0.1)


func test_the_period_line_carries_the_cadence() -> void:
	var probe := MovementProbe.new()
	var usec: int = _stream(probe, 33_333, 10)
	var lines: PackedStringArray = probe.on_frame(Vector3.ZERO, MovementProbe.PERIOD_S, true, usec)
	assert_string_contains(lines[lines.size() - 1], "net rate 30.0 Hz over 9")


func test_the_clocks_split_the_trip() -> void:
	var probe := MovementProbe.new()
	probe.on_frame(Vector3.ZERO, FRAME_S, true, 0)
	for i: int in 5:
		var server_ms: float = 1_000_000.0 + 33.0 * i
		probe.on_target(Vector3(0.13 * i, 0, 0), 70_000 * i, i,
				PackedFloat64Array([server_ms, server_ms + 4.0, server_ms + 4.0 + 10.0 * i]))
	var trip: Dictionary = probe.trip()
	assert_eq(trip["server_gap"], [33.0, 33.0, 33.0], "the server's own cadence, whatever the arrivals")
	assert_eq(trip["to_horizon"][2], 4.0)
	assert_eq(trip["in_horizon"][2], 40.0)


func test_no_clocks_no_trip() -> void:
	var probe := MovementProbe.new()
	_stream(probe, 33_333, 5)
	assert_eq(probe.trip()["server_gap"], [])
	var lines: PackedStringArray = probe.on_frame(Vector3.ZERO, MovementProbe.PERIOD_S, true, 200_000)
	assert_string_contains(lines[lines.size() - 1], "trip ms: server_gap -, to_horizon -, in_horizon -")
