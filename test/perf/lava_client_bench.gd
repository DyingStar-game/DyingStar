extends Node
## Main-thread cost of a client's lava runtime during an eruption, without network: a real Tarsis III volcano
## is sampled, an authority catches the eruption up to --lava-at seconds, then a client runtime installs its
## checkpoint and is driven frame by frame on the same clock. Prints the per-frame cost of the runtime's
## _process and of its parts (texture packing, edge-smoke scan).
##
##   godot --headless --path . res://test/perf/lava_client_bench.tscn -- --lava-at=323 --fps=32

const Runtime = preload("res://scenes/planet/lava/lava_planet_runtime.gd")
const Builder = preload("res://scenes/planet/lava/lava_planet_patch.gd")
const START_S := 1800000000.0
const VOLCANO := "@-39.754773,25.066776"
var _clock := [0]


func _ready() -> void:
	_run.call_deferred()


func _arg(name: String, fallback: float) -> float:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return float(a.get_slice("=", 1))
	return fallback


func _run() -> void:
	var at_s := _arg("lava-at", 323.0)
	var fps := _arg("fps", 32.0)
	var frames := int(_arg("frames", 400.0))
	var data: PlanetData = SystemScenes.root_properties("res://scenes/systems/tarsis/tarsis_3.tscn").planet_data.duplicate(true)
	data.apply_chunk_manifest()
	data.ensure_queries_loaded()
	data.warm_mountains()
	var volcano: VolcanoRelief.Volcano = null
	for ip in 12:
		for v: VolcanoRelief.Volcano in data.get_chunk_volcanoes(1, ip):
			if VolcanoFeatures.key_of(v) == VOLCANO or (volcano == null and v.activity == "active" and v.rc >= 24.0):
				volcano = v
	print("BENCH volcano ", VolcanoFeatures.key_of(volcano))
	var packet := Builder.build(data, volcano)
	var description: Dictionary = packet.duplicate()
	description.key = "bench"
	description.planet = data.planet_name
	description.plan = Builder.eruption_plan({"start_unix": START_S, "length_s": 2400.0, "strength": 1.57}, packet)
	_clock[0] = int(START_S * 1000.0) + int(at_s * 1000.0)

	var authority: Node3D = Runtime.new()
	authority.setup(data, true)
	authority.catch_up_ticks = 200
	authority.clock_ms = func() -> int: return _clock[0]
	add_child(authority)
	if not authority.install_patch(description):
		print("BENCH FAIL authority install")
		get_tree().quit(1)
		return
	var started := Time.get_ticks_msec()
	while authority.patch_tick("bench") < authority.target_tick("bench"):
		await get_tree().process_frame
	print("BENCH authority at tick %d in %d ms" % [authority.patch_tick("bench"), Time.get_ticks_msec() - started])
	authority.set_process(false)

	var camera := Camera3D.new()
	add_child(camera)
	camera.make_current()
	var client: Node3D = Runtime.new()
	client.setup(data, false)
	client.clock_ms = func() -> int: return _clock[0]
	client.set_process(false)
	add_child(client)
	var replica := description.duplicate()
	replica.checkpoint = authority.patch_checkpoint("bench")
	started = Time.get_ticks_usec()
	if not client.install_patch(replica):
		print("BENCH FAIL client install")
		get_tree().quit(1)
		return
	print("BENCH client install %.1f ms" % ((Time.get_ticks_usec() - started) / 1000.0))
	var entry: Dictionary = client.patches["bench"]
	print("BENCH wet %d active %d" % [entry.solver.wet_indices.size(), entry.solver.active_indices.size()])

	var totals := PackedFloat64Array()
	var publishes := PackedFloat64Array()
	var dt := 1.0 / fps
	var step_ms := 0.0
	for n in frames:
		step_ms += dt * 1000.0
		_clock[0] += int(step_ms)
		step_ms -= int(step_ms)
		var before: int = entry.surface.publications if entry.surface != null else 0
		var t0 := Time.get_ticks_usec()
		client._process(dt)
		totals.append((Time.get_ticks_usec() - t0) / 1000.0)
		if entry.surface != null and entry.surface.publications != before:
			publishes.append(client.last_visual_ms)
		await get_tree().process_frame
	_report("process/frame", totals)
	_report("publish (main)", publishes)

	# Parts, on the final state, repeated.
	var solver = entry.solver
	var scans := PackedFloat64Array()
	var applies := PackedFloat64Array()
	var packs := PackedFloat64Array()
	var uploads := PackedFloat64Array()
	var dirties := PackedFloat64Array()
	for n in 20:
		var t0 := Time.get_ticks_usec()
		var found: Array = entry.smoke.edges_of(solver)
		scans.append((Time.get_ticks_usec() - t0) / 1000.0)
		t0 = Time.get_ticks_usec()
		entry.smoke.apply_edges(found)
		applies.append((Time.get_ticks_usec() - t0) / 1000.0)
		solver.refresh_views(true)
		dirties.append(solver.visual_dirty.size())
		t0 = Time.get_ticks_usec()
		entry.surface.prepare(solver, 0.1, true)
		packs.append((Time.get_ticks_usec() - t0) / 1000.0)
		t0 = Time.get_ticks_usec()
		entry.surface.upload()
		uploads.append((Time.get_ticks_usec() - t0) / 1000.0)
	_report("smoke edges_of (worker)", scans)
	_report("smoke apply_edges (main)", applies)
	_report("surface.prepare all wet (worker)", packs)
	_report("surface.upload (main)", uploads)
	_report("dirty cells", dirties)
	get_tree().quit(0)


func _report(label: String, values: PackedFloat64Array) -> void:
	if values.is_empty():
		print("BENCH %s: none" % label)
		return
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for v in values: total += v
	print("BENCH %s: n=%d mean=%.2f p50=%.2f p95=%.2f max=%.2f" % [label, values.size(), total / values.size(),
		sorted[sorted.size() / 2], sorted[int(sorted.size() * 0.95)], sorted[-1]])
