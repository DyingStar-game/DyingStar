extends SceneTree
const Core = preload("res://scenes/planet/lava/lava_fixed_core.gd")
const WEEK_TICKS := 6048000

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var server := Core.new()
	var bed := PackedInt64Array(); bed.resize(32 * 32); bed.fill(0)
	server.configure_q(32, 32, 8000, bed)
	server.yield_q = 0
	server.viscosity_q = 300
	if not server.has_native_backend():
		push_error("The week test requires the compiled integer kernel")
		quit(1); return
	var commands := PackedInt64Array()
	for i in bed.size(): commands.append_array(PackedInt64Array([i, 1000, 8000]))
	server.inject_q(commands)
	Core.use_native = false
	var client := Core.new()
	client.restore(server.checkpoint())
	Core.use_native = true
	var same := true
	var comparisons := 0
	var visits := 0
	var started := Time.get_ticks_usec()
	for tick in range(1, WEEK_TICKS + 1):
		var input := PackedInt64Array([528, 10, 200]) if tick % 864000 == 0 else PackedInt64Array()
		same = server.advance_tick(tick, input) and client.advance_tick(tick, input) and same
		if tick > 1: visits += server.last_updated_cells
		if tick % 864000 == 0:
			same = same and server.checkpoint() == client.checkpoint()
			comparisons += 1
			print("LAVA_WEEK day=", comparisons, " updated_cells_total=", visits)
			await process_frame
	var sleeping_state := server.checkpoint()
	var resumed := Core.new()
	same = resumed.restore(sleeping_state) and resumed.checkpoint() == sleeping_state and same
	var hot := PackedInt64Array([528, 10000, 14000])
	for n in 50:
		var input := hot if n == 0 else PackedInt64Array()
		var next := server.tick + 1
		same = server.advance_tick(next, input) and client.advance_tick(next, input) and resumed.advance_tick(next, input) and same
		same = same and server.checkpoint() == client.checkpoint() and server.checkpoint() == resumed.checkpoint()
	var heated_receivers := 0
	var remaining := 0
	for i in server.wet_indices:
		remaining += server.volume_q[i]
		if server.current_energy_q(i) > 0: heated_receivers += 1
	var report := {"model": Core.SCHEMA, "simulated_days": 7, "ticks_per_peer": WEEK_TICKS,
		"deposited_cells": bed.size(), "updated_cells_after_first_tick": visits,
		"daily_comparisons": comparisons, "heated_cells_after_reactivation": heated_receivers,
		"bit_identical_including_reheat_and_late_join": same,
		"native_server": server.has_native_backend(), "reference_client": not client.has_native_backend(),
		"remaining_m3": remaining / 1000.0, "mass_conserved": remaining == server.injected_q,
		"wall_seconds": (Time.get_ticks_usec() - started) / 1000000.0,
		"sha256_after_reheat": server.state_digest(),
		"scope": "stable deposited field, daily cold inputs, then hot reactivation; not continuous full-volcano discharge"}
	FileAccess.open("user://lava-sleep-week.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("LAVA_WEEK_RESULT ", JSON.stringify(report))
	quit(0 if same and visits < 100 and heated_receivers > 1 and remaining == server.injected_q else 1)
