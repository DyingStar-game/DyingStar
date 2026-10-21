extends GutTest
## NetInterpolator's lead: the owner's body keeps going between two positions while its keys are held,
## and never runs past a stop.

const GAP_US: int = 70_000  # what the probe measured: ~14 positions a second


func _fed(interp: NetInterpolator, node: Node3D) -> void:
	interp.set_position_target(node, Vector3.ZERO, 0)
	interp.set_position_target(node, Vector3(0.5, 0, 0), GAP_US)  # 0.5 m in 70 ms: a run


func test_held_keys_carry_the_target_on_at_the_measured_speed() -> void:
	var interp := NetInterpolator.new()
	var node := Node3D.new()
	_fed(interp, node)
	var half: Vector3 = interp.lead_target(true, GAP_US + GAP_US / 2)
	assert_almost_eq(half.x, 0.75, 1e-6, "half a gap on: a quarter metre further")
	node.free()


## A position a little late is waited for at speed; a stream that stopped (a wall: the server sends
## nothing for a body that does not move) is not run after, nor held ahead.
func test_the_lead_waits_for_a_late_position_and_lets_a_stopped_one_go() -> void:
	var interp := NetInterpolator.new()
	var node := Node3D.new()
	_fed(interp, node)
	var late: float = interp.lead_target(true, GAP_US + GAP_US * 6 / 5).x
	assert_almost_eq(late, 0.5 + 0.5 * 1.2, 1e-6, "20 % late: still going")
	assert_almost_eq(interp.lead_target(true, GAP_US + 10 * GAP_US).x, 0.5, 1e-6,
			"stopped against a wall, key held: back on what the server said")
	node.free()


func test_the_lead_comes_back_as_fast_as_it_went() -> void:
	assert_eq(NetInterpolator.lead_time(0.05, 0.1), 0.05)
	assert_almost_eq(NetInterpolator.lead_time(0.15, 0.1), 0.05, 1e-9, "past the cap: coming back")
	assert_eq(NetInterpolator.lead_time(0.3, 0.1), 0.0)


func test_released_keys_settle_on_what_the_server_said() -> void:
	var interp := NetInterpolator.new()
	var node := Node3D.new()
	_fed(interp, node)
	assert_eq(interp.lead_target(false, GAP_US * 2), Vector3(0.5, 0, 0))
	node.free()


func test_a_reset_forgets_the_speed() -> void:
	var interp := NetInterpolator.new()
	var node := Node3D.new()
	_fed(interp, node)
	interp.snap_next()
	interp.set_position_target(node, Vector3(100, 0, 0), GAP_US * 2)  # another frame
	assert_eq(interp.lead_target(true, GAP_US * 3), Vector3(100, 0, 0), "no speed across a reparent")
	node.free()


## Positions that waited in the socket come in the same frame: the speed is the server clock's.
func test_the_speed_is_measured_against_the_server_clock() -> void:
	var interp := NetInterpolator.new()
	var node := Node3D.new()
	interp.set_position_target(node, Vector3.ZERO, 0, 1000.0)
	interp.set_position_target(node, Vector3(0.25, 0, 0), 16_000, 1066.0)  # 66 ms apart, came 16 ms apart
	var on: Vector3 = interp.lead_target(true, 16_000 + 33_000)
	assert_almost_eq(on.x, 0.25 + 0.25 / 0.066 * 0.033, 1e-4, "about 3.8 m/s, not 15")
	node.free()


func test_another_servers_clock_gives_no_speed() -> void:
	var interp := NetInterpolator.new()
	var node := Node3D.new()
	interp.set_position_target(node, Vector3.ZERO, 0, 5000.0)
	interp.set_position_target(node, Vector3(0.25, 0, 0), 66_000, 1000.0)  # hand-over: clock went back
	assert_eq(interp.lead_target(true, 100_000), Vector3(0.25, 0, 0))
	node.free()


## A glide is over once the node is on its target: settle puts it there exactly and says so, so its
## owner (PropSync) can stop calling update.
func test_a_glide_settles_on_its_target() -> void:
	var node := Node3D.new()
	autofree(node)
	var interp := NetInterpolator.new()
	interp.set_target(node, Vector3.ZERO, Basis.IDENTITY)
	interp.set_target(node, Vector3(1, 0, 0), Basis.IDENTITY)
	assert_false(interp.settle(node), "a metre away")
	var frames := 0
	while not interp.settle(node) and frames < 200:
		interp.update(node, 1.0 / 60.0)
		frames += 1
	assert_lt(frames, 200, "it gets there")
	assert_eq(node.position, Vector3(1, 0, 0), "exactly on it")
	assert_true(NetInterpolator.new().settle(node), "no target: nothing to glide to")
