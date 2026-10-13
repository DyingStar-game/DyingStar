extends GutTest
## DustCostProbe: one log line per period with the dust's CPU time per frame (mean and worst), each
## ground grid's share, the GPU frame time and what the layer drew; nothing between periods.


func test_a_line_per_period_with_the_means() -> void:
	var probe := DustCostProbe.new()
	var grid := DustGround.new()
	var grids := {"near": grid}
	var layer := {"near": 0.0013, "near_steps": 20, "far": 0.0002, "far_steps": 10, "lamps": 1, "setting": 2}
	var line: String = ""
	for i in 150:
		grid.spent_ground_us += 500
		line = probe.frame(100, 900, grids, 6.0, 1.0 / 60.0, layer)
		if not line.is_empty():
			break
	assert_string_contains(line, "[DustCost]")
	assert_string_contains(line, "cpu dust 1.00 ms/frame", "100 + 900 µs a frame")
	assert_string_contains(line, "near grid 0.50 ms/frame", "the grid's share, read off it")
	assert_string_contains(line, "gpu frame 6.00 ms")
	assert_string_contains(line, "near 0.00130 /m x 20 steps")
	assert_eq(grid.spent_ground_us, 0, "the grid's time is taken, not counted twice")
	assert_eq(probe.frame(0, 0, grids, 6.0, 1.0 / 60.0, layer), "", "then quiet until the next period")


func test_a_parameter_never_set_reads_zero() -> void:
	var probe := DustCostProbe.new()
	var line: String = probe.report({}, {"near": null, "near_steps": null, "setting": 2})
	assert_string_contains(line, "near 0.00000 /m x 0 steps", "null from the shader: 0, not a crash")
