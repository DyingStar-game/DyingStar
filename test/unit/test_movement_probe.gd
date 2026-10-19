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
