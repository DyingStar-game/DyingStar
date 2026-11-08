extends SceneTree
const Core = preload("res://scenes/planet/lava/lava_fixed_core.gd")
const Client = preload("res://scenes/planet/lava/viscous_lava_solver.gd")

func _initialize() -> void:
	call_deferred("_run")

func _case(sleeping: bool, hot_cells: int) -> Dictionary:
	var server := Core.new()
	var bed := PackedInt64Array(); bed.resize(96 * 96); bed.fill(0)
	server.configure_q(96, 96, 64000, bed)
	server.use_sleeping = sleeping
	var source := PackedInt64Array()
	for i in bed.size(): source.append_array(PackedInt64Array([i, 1000000, 12000 if i < hot_cells else 200]))
	server.inject_q(source)
	var client := Client.new()
	client.restore(server.checkpoint()); client.use_sleeping = sleeping
	var samples: Array[float] = []
	var visited := 0
	for tick in range(1, 211):
		var before := Time.get_ticks_usec()
		server.advance_tick(tick); client.advance_tick(tick)
		if tick > 10:
			samples.append((Time.get_ticks_usec() - before) / 1000.0)
			visited = maxi(visited, server.last_updated_cells)
	samples.sort()
	assert(server.checkpoint() == client.checkpoint())
	return {"sleeping": sleeping, "hot_cells": hot_cells, "grid": [96, 96],
		"pair_p50_ms": samples[samples.size() / 2], "pair_p95_ms": samples[int(samples.size() * 0.95)],
		"max_updated_cells": visited, "wet_cells": server.wet_indices.size(),
		"native": server.has_native_backend(), "sha256": server.state_digest()}

func _run() -> void:
	var cases := []
	for hot in [0, 8]:
		var full := _case(false, hot)
		var sleepy := _case(true, hot)
		if full.sha256 != sleepy.sha256:
			push_error("Sleep benchmark changed canonical state"); quit(1); return
		cases.append(full); cases.append(sleepy)
	var report := {"model": Core.SCHEMA, "cpu": OS.get_processor_name(), "cases": cases}
	FileAccess.open("user://lava-sleep-benchmark.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("LAVA_SLEEP_BENCHMARK ", JSON.stringify(report))
	quit()
