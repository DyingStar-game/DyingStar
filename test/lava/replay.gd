extends SceneTree
const Core = preload("res://scenes/planet/lava/lava_fixed_core.gd")
const Client = preload("res://scenes/planet/lava/viscous_lava_solver.gd")
const GOLDEN_V6 := "743f84c5bf21667af70625e61491ba7d4355f163c4b3d5b41edd43ea8a518961"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var role := "server"
	var output := "user://lava-replay.json"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="): role = arg.trim_prefix("--role=")
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	var sim = Client.new() if role == "client" else Core.new()
	var terrain := PackedInt64Array()
	terrain.resize(32 * 48)
	for z in 48:
		for x in 32:
			var offset := x * 2250 - 35000
			terrain[z * 32 + x] = 13000 - z * 405 + offset * offset / 72000
	if not sim.configure_q(32, 48, 2250, terrain):
		quit(1)
		return
	sim.inject_q(sim.disc_commands(37000, 9000, 3000, 24000, 11500))
	var hashes: Array = []
	var frame := 0
	var start := Time.get_ticks_usec()
	while sim.tick < 2000:
		var batch := 1 if role == "server" else (frame * 7) % 6
		frame += 1
		for n in batch:
			if sim.tick >= 2000: break
			var next: int = sim.tick + 1
			if next == 400: sim.viscosity_q = 18000
			if next == 700: sim.viscosity_q = 1800
			var commands := PackedInt64Array()
			if next < 1200 or next >= 1600:
				commands = sim.disc_commands(37000, 9000, 3000, 400, 11500)
			if not sim.advance_tick(next, commands):
				push_error("Rejected replay tick " + str(next))
				quit(1)
				return
			if next % 100 == 0:
				hashes.append({"tick": next, "sha256": sim.state_digest()})
	if sim.state_digest() != GOLDEN_V6:
		push_error("Model v6 golden replay diverged: " + sim.state_digest())
		quit(1)
		return
	var report := {"role": role, "schema": Core.SCHEMA, "ticks": sim.tick,
		"frame_batches": frame, "duration_ms": (Time.get_ticks_usec() - start) / 1000.0,
		"hashes": hashes, "final_sha256": sim.state_digest(), "canonical_bytes": sim.checkpoint().size(),
		"engine": Engine.get_version_info().string, "os": OS.get_name(), "cpu": OS.get_processor_name()}
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	var binary := FileAccess.open(output.get_basename() + ".bin", FileAccess.WRITE)
	binary.store_buffer(sim.checkpoint())
	print("LAVA_REPLAY ", role, " ticks=", sim.tick, " digest=", sim.state_digest())
	quit()
