extends GutTest
## WeatherBench: the statistics of a stage, the result table against the first stage, the switches
## turned on one stage at a time and all back off when the bench leaves, and a building laid during a
## run without colliders gets a hidden one.

const KNOWN: Array = [&"no_layer", &"no_masks", &"no_colliders", &"no_particles", &"no_storm", &"low_steps"]


func after_each() -> void:
	WeatherBench.no_layer = false
	WeatherBench.no_masks = false
	WeatherBench.no_colliders = false
	WeatherBench.no_particles = false
	WeatherBench.no_storm = false


func test_stats_of_a_stage() -> void:
	var s: Dictionary = WeatherBench.stats(PackedFloat64Array([4.0, 1.0, 3.0, 2.0]))
	assert_almost_eq(float(s["mean"]), 2.5, 1e-9)
	assert_almost_eq(float(s["median"]), 2.5, 1e-9, "even count: the mean of the two middle samples")
	assert_eq(int(s["count"]), 4)
	var odd: Dictionary = WeatherBench.stats(PackedFloat64Array([9.0, 1.0, 5.0]))
	assert_almost_eq(float(odd["median"]), 5.0, 1e-9)
	assert_almost_eq(float(odd["p95"]), 9.0, 1e-9)
	assert_eq(int(WeatherBench.stats(PackedFloat64Array())["count"]), 0, "no frame measured: zeros, no error")


func test_the_table_gives_each_stage_its_saving_against_the_first() -> void:
	var results: Array = [
		["all", {"median": 10.0}, {}],
		["no_layer", {"median": 6.5}, {}],
	]
	var lines: PackedStringArray = WeatherBench.table(results)
	assert_eq(lines.size(), 2)
	assert_string_contains(lines[0], "saving  +0.00")
	assert_string_contains(lines[1], "saving  +3.50", "the layer costs 3.5 ms")


func test_every_stage_names_known_switches_and_the_run_starts_and_ends_on_everything() -> void:
	for stage: Array in WeatherBench.STAGES:
		for switch: StringName in stage[1]:
			assert_has(KNOWN, switch, "stage %s" % stage[0])
	assert_eq((WeatherBench.STAGES[0][1] as Array).size(), 0)
	assert_eq((WeatherBench.STAGES[-1][1] as Array).size(), 0, "the drift check repeats the first stage")


func test_a_stage_turns_on_only_its_switches_and_leaving_turns_them_all_off() -> void:
	var bench := WeatherBench.new(null)
	bench._apply([&"no_layer", &"no_storm"])
	assert_true(WeatherBench.no_layer)
	assert_true(WeatherBench.no_storm)
	assert_false(WeatherBench.no_masks)
	assert_false(WeatherBench.no_particles)
	bench._apply([&"no_particles"])
	assert_false(WeatherBench.no_layer, "the previous stage's switch is off again")
	assert_true(WeatherBench.no_particles)
	add_child(bench)  # _ready enters the first stage: everything on
	bench.set_process(false)
	bench._apply([&"no_particles"])
	remove_child(bench)
	assert_false(WeatherBench.no_particles, "a bench leaving the tree leaves the weather as it was")
	bench.free()


func test_a_building_boxed_during_a_run_without_colliders_gets_a_hidden_one() -> void:
	WeatherBench.no_colliders = true
	var root := Node3D.new()
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10.0, 4.0, 6.0)
	cs.shape = box
	body.add_child(cs)
	root.add_child(body)
	add_child_autofree(root)
	WeatherMasks._box(root)
	var collider := root.get_node_or_null(^"WeatherMaskCollider") as GPUParticlesCollisionBox3D
	assert_not_null(collider)
	assert_false(collider.visible)
