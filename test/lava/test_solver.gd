extends SceneTree
const Core = preload("res://scenes/planet/lava/lava_fixed_core.gd")
const Client = preload("res://scenes/planet/lava/viscous_lava_solver.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	checks += 1
	if condition: print("PASS: ", message)
	else:
		failures += 1
		push_error("FAIL: " + message)

func _make(nx: int = 16, nz: int = 24, slope_mm: int = 200) -> Core:
	var sim := Core.new()
	var bed := PackedInt64Array()
	bed.resize(nx * nz)
	for z in nz:
		for x in nx: bed[z * nx + x] = -z * slope_mm
	sim.configure_q(nx, nz, 1000, bed)
	sim.cooling_enabled = false
	return sim

func _sum(values: PackedInt64Array) -> int:
	var result := 0
	for value in values: result += value
	return result

func _run() -> void:
	var sim := _make()
	var before := sim.checkpoint()
	_check(not sim.configure_q(257, 3, 1000, PackedInt64Array()) and sim.checkpoint() == before, "reject oversized grid atomically")
	_check(not sim.advance_tick(2) and sim.checkpoint() == before, "reject missing tick without changing state")
	_check(not sim.inject_q(PackedInt64Array([2, 100, 11500, 1, 200, 11500])) and sim.checkpoint() == before,
			"reject reordered source cells atomically")
	_check(not sim.inject_q(PackedInt64Array([1, 100, 11500, 1, 200, 11500])), "reject duplicate source cells")
	_check(not sim.inject_q(PackedInt64Array([1, -1, 11500])) and not sim.inject_q(PackedInt64Array([1, 100, 15000])),
			"reject invalid source volume and temperature")
	var commands := sim.disc_commands(8000, 4000, 2200, 30007, 11500)
	var commanded := 0
	for p in range(1, commands.size(), 3): commanded += commands[p]
	_check(commanded == 30007, "source remainder is distributed without losing a volume quantum")
	_check(sim.inject_q(commands), "canonical source accepted")
	var heat := _sum(sim.energy_q)
	for n in 500: sim.advance_tick(sim.tick + 1)
	_check(_sum(sim.volume_q) == 30007, "exact volume conservation over 500 ticks")
	_check(_sum(sim.energy_q) == heat, "exact heat conservation without cooling")
	var nonnegative := true
	var downstream := 0
	for i in sim.volume_q.size():
		nonnegative = nonnegative and sim.volume_q[i] >= 0 and sim.energy_q[i] >= 0
		downstream += sim.volume_q[i] * (i / sim.width)
	_check(nonnegative, "nonnegative integer volume and thermal energy")
	_check(downstream > 5 * 30007, "centre of mass travels downhill")
	var duplicate := sim.checkpoint()
	_check(not sim.advance_tick(sim.tick) and sim.checkpoint() == duplicate, "duplicate network tick is rejected")
	var restored := Core.new()
	_check(restored.restore(duplicate) and restored.checkpoint() == duplicate, "checkpoint restores every authoritative bit")
	var equal := true
	for n in 100:
		sim.advance_tick(sim.tick + 1)
		restored.advance_tick(restored.tick + 1)
		equal = equal and sim.state_digest() == restored.state_digest()
	_check(equal, "late join checkpoint replays exactly for 100 further ticks")
	var invalid := duplicate.duplicate()
	invalid[15] = 99
	var saved := restored.checkpoint()
	_check(not restored.restore(invalid) and restored.checkpoint() == saved, "wrong model version cannot overwrite live state")
	_check(not restored.restore(duplicate.slice(0, duplicate.size() - 1)), "truncated checkpoint is rejected")
	var barrier := _make()
	for x in barrier.width: barrier.terrain_q[10 * barrier.width + x] = 64000
	barrier.inject_q(barrier.disc_commands(8000, 6000, 2200, 100000, 11500))
	for n in 300: barrier.advance_tick(barrier.tick + 1)
	var beyond := 0
	for i in range(11 * barrier.width, barrier.volume_q.size()): beyond += barrier.volume_q[i]
	_check(beyond == 0, "continuous terrain barrier blocks lava")
	var cold := _make()
	cold.inject_q(cold.disc_commands(8000, 4000, 2000, 15000, 9400))
	var frozen := cold.volume_q.duplicate()
	for n in 20: cold.advance_tick(cold.tick + 1)
	_check(cold.volume_q == frozen, "sub-solidus deposit remains immobile")
	var yielded := _make()
	yielded.yield_q = 1000000000
	yielded.inject_q(yielded.disc_commands(8000, 4000, 2000, 15000, 11500))
	var held := yielded.volume_q.duplicate()
	yielded.advance_tick(1)
	_check(yielded.volume_q == held, "yield stress can arrest flow")
	var mirror := _make(17, 17, 0)
	mirror.inject_q(mirror.disc_commands(8000, 8000, 1000, 30000, 11500))
	for n in 100: mirror.advance_tick(mirror.tick + 1)
	var error := 0
	for z in 17:
		for x in 17: error = maxi(error, absi(mirror.volume_q[z * 17 + x] - mirror.volume_q[z * 17 + 16 - x]))
	_check(error == 0, "simultaneous fluxes preserve exact mirror symmetry")
	var cooler := _make()
	cooler.cooling_enabled = true
	cooler.inject_q(cooler.disc_commands(8000, 4000, 2000, 20000, 11500))
	var hot := _sum(cooler.energy_q)
	for n in 200: cooler.advance_tick(cooler.tick + 1)
	_check(_sum(cooler.energy_q) < hot and _sum(cooler.volume_q) == 20000, "integer cooling removes heat and retains all volume")
	_check(cooler.mu_at(10300) > 8 * cooler.mu_at(11500), "versioned viscosity table stiffens colder lava")
	var extreme := _make()
	extreme.viscosity_q = 1
	extreme.yield_q = 0
	extreme.inject_q(PackedInt64Array([72, 512000, 14000]))
	for n in 300: extreme.advance_tick(extreme.tick + 1)
	var bounded := true
	for v in extreme.volume_q: bounded = bounded and v >= 0 and v <= 512000
	_check(bounded and _sum(extreme.volume_q) == 512000, "limiter survives maximum supported depth and low viscosity")
	var client := Client.new()
	_check(client.restore(sim.checkpoint()), "client adapter loads canonical server state")
	var canonical := client.state_digest()
	client.depth.fill(999.0)
	client.temperature.fill(-123.0)
	client.elapsed_s = 1000000.0
	_check(client.state_digest() == canonical, "presentation arrays and display time cannot affect authoritative state")
	client.advance_tick(client.tick + 1)
	sim.advance_tick(sim.tick + 1)
	_check(client.state_digest() == sim.state_digest(), "client presentation changes do not affect the next tick")
	_check(not client.step(0.01) and not client.step(NAN), "variable timesteps are unavailable to the authoritative model")
	var gravity_test := _make()
	gravity_test.gravity_milli = 7770
	var gravity_copy := Core.new()
	_check(gravity_copy.restore(gravity_test.checkpoint()) and gravity_copy.gravity_milli == 7770,
			"planet gravity is part of the canonical checkpoint")
	var cliff := _make(3, 3, 0)
	cliff.terrain_q[4] = Core.MAX_TERRAIN_SPAN_MM
	cliff.gravity_milli = 50000
	cliff.viscosity_q = 1
	cliff.yield_q = 0
	cliff.inject_q(PackedInt64Array([4, 512000, 14000]))
	var cliff_valid := true
	for n in 100:
		cliff_valid = cliff.advance_tick(cliff.tick + 1) and cliff_valid
		for v in cliff.volume_q: cliff_valid = cliff_valid and v >= 0 and v <= 512000
	_check(cliff_valid and _sum(cliff.volume_q) == 512000, "maximum planetary relief, gravity and depth remain positive without overflow")
	var wide := Core.new()
	wide.configure_q(3, 3, 8000, PackedInt64Array([0, 0, 0, 0, Core.MAX_TERRAIN_SPAN_MM, 0, 0, 0, 0]))
	wide.gravity_milli = 50000
	wide.viscosity_q = 1
	wide.yield_q = 0
	wide.cooling_enabled = false
	wide.inject_q(PackedInt64Array([4, 32768000, 14000]))
	var wide_heat := _sum(wide.energy_q)
	var wide_valid := true
	for n in 100:
		wide_valid = wide.advance_tick(wide.tick + 1) and wide_valid
		for v in wide.volume_q: wide_valid = wide_valid and v >= 0 and v <= 32768000
	_check(wide_valid and _sum(wide.volume_q) == 32768000 and _sum(wide.energy_q) == wide_heat,
		"8m cells conserve maximum-depth volume and heat at maximum relief/gravity without overflow")
	var wide_copy := Core.new()
	_check(wide_copy.restore(wide.checkpoint()), "large-cell checkpoint restores including its derived wet index")
	wide_copy.active_indices.reverse()
	wide_copy.wet_indices.reverse() # Derived traversal order must never affect canonical evolution.
	wide.advance_tick(wide.tick + 1)
	wide_copy.advance_tick(wide_copy.tick + 1)
	_check(wide.checkpoint() == wide_copy.checkpoint(), "reordered sparse traversal cannot change a physical bit")
	_test_polar_and_cleanup()
	_test_sleep()
	await _test_workers()
	print("LAVA_TESTS ", checks - failures, "/", checks, " passed")
	quit(0 if failures == 0 else 1)


func _test_polar_and_cleanup() -> void:
	var sim := Core.new()
	var edges := PackedInt64Array()
	for r in 13: edges.append(r * 1000)
	var bed := PackedInt64Array()
	for r in 12:
		for sector in 32: bed.append(0 if r < 4 else 2000 - (r - 4) * 500)
	_check(sim.configure_polar_q(32, edges, bed), "polar field accepts integer radial geometry")
	sim.cooling_enabled = false
	sim.viscosity_q = 300
	sim.yield_q = 20
	var input := PackedInt64Array()
	for i in 64: input.append_array(PackedInt64Array([i, 100, 12000]))
	var valid := true
	for n in 200: valid = sim.advance_tick(sim.tick + 1, input if n < 100 else PackedInt64Array()) and valid
	_check(valid and _sum(sim.volume_q) == 640000, "polar fluxes conserve exact litres across unequal cell areas")
	var symmetry := true
	var sides := 0
	for sector in 32:
		var outside := 0
		for r in 12:
			symmetry = symmetry and sim.volume_q[r * 32 + sector] == sim.volume_q[r * 32]
			if r > 4: outside += sim.volume_q[r * 32 + sector]
		if outside > 0: sides += 1
	_check(symmetry and sides == 32, "a filled crater overflows in every direction, including the angular seam")
	var resumed := Core.new()
	_check(resumed.restore(sim.checkpoint()) and resumed.radial_edges_mm == edges, "polar geometry is canonical in late-join checkpoints")
	resumed.active_indices.reverse()
	resumed.wet_indices.reverse()
	sim.advance_tick(sim.tick + 1)
	resumed.advance_tick(resumed.tick + 1)
	_check(sim.checkpoint() == resumed.checkpoint(), "polar traversal order cannot affect the next tick")
	sim.cleanup_enabled = true
	var last := sim.last_source_tick
	while sim.tick < last + Core.SOURCE_IDLE_TICKS + Core.FADE_DELAY_TICKS:
		sim.advance_tick(sim.tick + 1)
	var black := true
	for i in sim.wet_indices: black = black and Core.AMBIENT_T + sim.energy_q[i] / sim.volume_q[i] <= Core.BLACK_T
	_check(black and sim.removed_q > 0, "deposits are already black before progressive despawn starts")
	var fade_copy := Core.new()
	_check(fade_copy.restore(sim.checkpoint()), "partial cooling and fade timers survive a checkpoint")
	var same := true
	var ledger := true
	for n in Core.FADE_DURATION_TICKS:
		sim.advance_tick(sim.tick + 1)
		fade_copy.advance_tick(fade_copy.tick + 1)
		if n % 100 == 0:
			same = same and sim.checkpoint() == fade_copy.checkpoint()
			ledger = ledger and _sum(sim.volume_q) + sim.removed_q == sim.injected_q
	_check(same and ledger, "both peers account for every removed litre throughout despawn")
	_check(sim.cleanup_complete() and sim.wet_indices.is_empty() and sim.removed_q == sim.injected_q,
		"completed cleanup frees the wet index and retains a complete removal ledger")
	_check(sim.advance_tick(sim.tick + 1, input) and not sim.wet_indices.is_empty(), "a new eruption can reuse a fully despawned field")
	var huge := Core.new()
	var cliff := PackedInt64Array([0, 0, 0, 0, Core.MAX_TERRAIN_SPAN_MM, 0, 0, 0, 0])
	huge.configure_q(3, 3, 64000, cliff)
	huge.cooling_enabled = false
	huge.gravity_milli = 50000
	huge.viscosity_q = 1
	huge.yield_q = 0
	var amount := huge.capacities_q[4]
	huge.inject_q(PackedInt64Array([4, amount, 14000]))
	var heat := _sum(huge.energy_q)
	var bounded := true
	for n in 100:
		bounded = huge.advance_tick(huge.tick + 1) and bounded
		for i in 9: bounded = bounded and huge.volume_q[i] >= 0 and huge.volume_q[i] <= huge.capacities_q[i]
	_check(bounded and _sum(huge.volume_q) == amount and _sum(huge.energy_q) == heat,
		"maximum 512m depth, 8km relief and 64m cells do not overflow signed integers")
	_check(Core.mul_div(40000000000, 40000000000, 80000000000) == 20000000000,
		"wide multiply/divide preserves an exact result when the direct product would overflow")


func _test_workers() -> void:
	var a := _make()
	var b := Client.new()
	b.restore(a.checkpoint())
	var same := true
	for tick in range(1, 51):
		var commands := a.disc_commands(8000, 4000, 2200, 400, 12000)
		var jobs: Array[RefCounted] = []
		var tasks: Array[int] = []
		for solver in [a, b]:
			var job = preload("res://scenes/planet/lava/lava_tick_job.gd").new()
			job.solver = solver; job.next_tick = tick; job.commands = commands
			jobs.append(job)
			tasks.append(WorkerThreadPool.add_task(job.run))
		while not WorkerThreadPool.is_task_completed(tasks[0]) or not WorkerThreadPool.is_task_completed(tasks[1]):
			await process_frame
		for task in tasks: WorkerThreadPool.wait_for_task_completion(task)
		same = same and jobs[0].ok and jobs[1].ok and a.checkpoint() == b.checkpoint()
	_check(same, "concurrent worker-thread server and client replay every authoritative bit identically")


func _test_sleep() -> void:
	var asleep := _make(9, 9, 0)
	asleep.cooling_enabled = true
	var input := PackedInt64Array()
	for i in 81: input.append_array(PackedInt64Array([i, 1000, 8000]))
	asleep.inject_q(input)
	var full := Core.new()
	full.restore(asleep.checkpoint())
	full.use_sleeping = false
	var same := true
	for n in 1500:
		asleep.advance_tick(asleep.tick + 1)
		full.advance_tick(full.tick + 1)
		if n % 100 == 0: same = same and asleep.checkpoint() == full.checkpoint()
	_check(same and asleep.last_updated_cells == 0 and asleep.wet_indices.size() == 81,
		"dormant black deposits match a full scan without visiting cold cells")
	var resumed := Core.new()
	_check(resumed.restore(asleep.checkpoint()) and resumed.checkpoint() == full.checkpoint(),
		"sleeping checkpoints materialize exact cooling and exposure for late join")
	asleep.cooling_enabled = false; full.cooling_enabled = false; resumed.cooling_enabled = false
	for n in 5:
		asleep.advance_tick(asleep.tick + 1); full.advance_tick(full.tick + 1); resumed.advance_tick(resumed.tick + 1)
	_check(asleep.checkpoint() == full.checkpoint() and resumed.checkpoint() == full.checkpoint(),
		"changing cooling wakes dormant cells without applying the setting retroactively")
	asleep.cooling_enabled = true; full.cooling_enabled = true; resumed.cooling_enabled = true
	var hot := PackedInt64Array([40, 10000, 14000])
	asleep.advance_tick(asleep.tick + 1, hot); full.advance_tick(full.tick + 1, hot); resumed.advance_tick(resumed.tick + 1, hot)
	for n in 50:
		asleep.advance_tick(asleep.tick + 1); full.advance_tick(full.tick + 1); resumed.advance_tick(resumed.tick + 1)
	_check(asleep.checkpoint() == full.checkpoint() and resumed.checkpoint() == full.checkpoint()
		and asleep.active_indices.size() > 0, "fresh lava reheats sleeping cells and their neighbours identically")
	var broken := StreamPeerBuffer.new()
	broken.big_endian = true; broken.data_array = asleep.checkpoint()
	broken.seek(144 + 8 * 81 * 8)
	broken.put_64(asleep.tick + 1)
	var before := resumed.checkpoint()
	_check(not resumed.restore(broken.data_array) and resumed.checkpoint() == before,
		"an invalid sleeping epoch cannot overwrite live state")

	var view := Client.new()
	var quiet := _make(9, 9, 0)
	quiet.inject_q(input)
	quiet.advance_tick(1)
	view.restore(quiet.checkpoint())
	view.take_visual_dirty()
	view.advance_tick(view.tick + 1)
	_check(view.visual_dirty.is_empty(), "resting deposits generate no redundant client publication")
