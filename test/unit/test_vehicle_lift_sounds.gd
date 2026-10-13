extends GutTest
## The vehicle lift is heard while it runs: the winch's hum at the top, the cart rolling down the rail
## (both loops that wait for the lift, not ambient sounds playing all the time), and a clunk at the
## platform when it starts or stops.

const LIFT := "res://scenes/_universe/structures/industrial/vehicle_lift/"


func test_the_machinery_loops_wait_for_the_lift() -> void:
	for at: Array in [["base/base.tscn", "Animated Axis/WinchHum"], ["platform/platform_system.tscn", "RollingNoise"]]:
		var scene: Node = (load(LIFT + str(at[0])) as PackedScene).instantiate()
		var loop := scene.get_node_or_null(str(at[1])) as AmbientLoop3D
		assert_not_null(loop, "%s: %s" % [at[0], at[1]])
		if loop != null:
			assert_not_null(loop.stream, "with its sound")
			assert_false(loop.autoplay, "silent until the lift runs")
		scene.free()


func test_the_platform_clunks_when_it_starts_or_stops() -> void:
	var script: GDScript = load(LIFT + "vehicle_lift.gd")
	assert_not_null(script.get_property_default_value("sfx_start_stop"), "the start / stop sound is set")


func test_an_ambient_loop_still_plays_on_its_own_by_default() -> void:
	var loop := AmbientLoop3D.new()
	assert_true(loop.autoplay, "a generator's hum needs nothing to start")
	loop.set_running(true)  # muted here (no player): nothing to do, and no error
	loop.free()


func test_the_rolling_falls_silent_just_before_the_clunk() -> void:
	var lift: GDScript = load(LIFT + "vehicle_lift.gd")
	assert_true(lift.rolling_heard(5.0, 0.15), "running down the rail: heard")
	assert_true(lift.rolling_heard(0.5, 0.15), "braking, still rumbling")
	assert_false(lift.rolling_heard(0.1, 0.15), "the last few centimetres: silent")
	assert_false(lift.at_rest(0.1), "but not at rest yet: the clunk waits")
	assert_true(lift.at_rest(0.0), "still: the clunk now")
	assert_false(lift.rolling_heard(0.0, 0.15), "stopped: silent")
