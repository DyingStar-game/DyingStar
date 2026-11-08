extends SceneTree
const Core = preload("res://scenes/planet/lava/lava_fixed_core.gd")
const Client = preload("res://scenes/planet/lava/viscous_lava_solver.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var results: Array = []
	for dimensions in [Vector2i(32, 48), Vector2i(48, 72), Vector2i(64, 96)]:
		for role in ["server", "client"]:
			for occupancy_percent in [10, 100]:
				var sim = Core.new() if role == "server" else Client.new()
				var terrain := PackedInt64Array()
				terrain.resize(dimensions.x * dimensions.y)
				for z in dimensions.y:
					for x in dimensions.x: terrain[z * dimensions.x + x] = -z * 150
				sim.configure_q(dimensions.x, dimensions.y, 1500, terrain)
				var commands := PackedInt64Array()
				for i in sim.volume_q.size() * occupancy_percent / 100:
					commands.append_array(PackedInt64Array([i, 1000 + (i % 17) * 10, 11500]))
				sim.inject_q(commands)
				for warmup in 10: sim.advance_tick(sim.tick + 1)
				var times: Array[float] = []
				for n in 160:
					var start := Time.get_ticks_usec()
					sim.advance_tick(sim.tick + 1)
					times.append((Time.get_ticks_usec() - start) / 1000.0)
				times.sort()
				var report := {"grid": [dimensions.x, dimensions.y], "role": role,
					"initial_occupancy_percent": occupancy_percent, "steps": times.size(),
					"step_ms_median": times[80], "step_ms_p95": times[152], "step_ms_max": times.back(),
					"cpu_ms_per_second_at_10hz_median": times[80] * 10,
					"includes_presentation_conversion": role == "client", "includes_gpu_upload_or_smoke": false}
				results.append(report)
				print("LAVA_BENCH ", JSON.stringify(report))
	var output := "user://lava-benchmark.json"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify({"schema": Core.SCHEMA, "engine": Engine.get_version_info(),
		"os": OS.get_name(), "cpu": OS.get_processor_name(), "results": results}, "\t"))
	quit()
