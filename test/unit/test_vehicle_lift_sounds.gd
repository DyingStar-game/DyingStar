extends GutTest
## The vehicle lift is heard while it runs: the winch's hum at the top, the cart rolling down the rail
## (both loops that wait for the lift, not ambient sounds playing all the time), and a clunk at the
## platform when it starts or stops.

const LIFT := "res://scenes/_universe/structures/industrial/vehicle_lift/"


## Each loop of the lift plays one of the lift's sounds/*.tres, the very resources the lift's root shows
## in its Sounds group: tuning them there is tuning what is heard.
func test_the_machinery_loops_wait_for_the_lift() -> void:
	for at: Array in [["base/base.tscn", "Animated Axis/WinchHum", "winch"],
			["platform/platform_system.tscn", "RollingNoise", "rolling"],
			["landings/upper_landing/upper_landing.tscn", "Departure Alarm", "alarm"],
			["landings/lower_landing/lower_landing.tscn", "Departure Alarm", "alarm"]]:
		var scene: Node = (load(LIFT + str(at[0])) as PackedScene).instantiate()
		var loop := scene.get_node_or_null(str(at[1])) as AmbientLoop3D
		assert_not_null(loop, "%s: %s" % [at[0], at[1]])
		if loop != null:
			assert_not_null(loop.sound, "with its sound")
			if loop.sound != null:
				assert_eq(loop.sound.resource_path, LIFT + "sounds/%s.tres" % at[2], "the lift's shared sound")
				assert_not_null(loop.sound.stream, "with its sample")
			assert_false(loop.autoplay, "silent until the lift runs")
		scene.free()
	# Headless (dummy renderer), freeing the models reports "Parameter material is null": the engine's,
	# not ours (see test_vehicle_lift_screens). Those, and only those, are expected.
	for err in get_errors():
		if "material" in str(err.code) or "material" in str(err.rationale):
			err.handled = true


func test_the_lift_root_shows_the_sounds_its_loops_play() -> void:
	var state := (load(LIFT + "vehicle_lift.tscn") as PackedScene).get_state()
	var shown := {}
	for i in state.get_node_property_count(0):
		shown[state.get_node_property_name(0, i)] = state.get_node_property_value(0, i)
	for sound: String in ["winch", "rolling", "alarm"]:
		var res := shown.get("sound_" + sound) as LoopSound
		assert_not_null(res, "sound_%s set on the lift" % sound)
		if res != null:
			assert_eq(res.resource_path, LIFT + "sounds/%s.tres" % sound, "the same file its loop plays")


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
