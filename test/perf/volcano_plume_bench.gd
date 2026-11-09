extends Node
## CPU cost of one VolcanoPlume (smoke + thrown stones) during a real Tarsis III eruption, eye on the flank:
## the plume's _process frame by frame on a frozen-then-advancing clock, then its parts on the final state.
## The GPU cost of the smoke is not measured here (headless).
##
##   godot --headless --path . res://test/perf/volcano_plume_bench.tscn -- --at=323 --fps=32 --eye-m=600

const VOLCANO := "@-39.754773,25.066776"


func _ready() -> void:
	_run.call_deferred()


func _arg(name: String, fallback: float) -> float:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return float(a.get_slice("=", 1))
	return fallback


func _run() -> void:
	var at_s := _arg("at", 323.0)
	var fps := _arg("fps", 32.0)
	var frames := int(_arg("frames", 600.0))
	var eye_m := _arg("eye-m", 600.0)
	var data: PlanetData = SystemScenes.root_properties("res://scenes/systems/tarsis/tarsis_3.tscn").planet_data.duplicate(true)
	data.apply_chunk_manifest()
	data.ensure_queries_loaded()
	data.warm_mountains()
	var volcano: VolcanoRelief.Volcano = null
	for ip in 12:
		for v: VolcanoRelief.Volcano in data.get_chunk_volcanoes(1, ip):
			if VolcanoFeatures.key_of(v) == VOLCANO:
				volcano = v
	var root := Node3D.new()
	add_child(root)
	var centre := volcano.c * (data.radius + data.volcano_lake_level(volcano))
	var plume := VolcanoPlume.create(data, volcano, centre)
	plume.position = centre
	root.add_child(plume)
	plume.set_process(false)
	plume.stones.set_physics_process(false)
	# A real eruptive slot of this volcano's schedule, at_s seconds in.
	var profile := plume.model.profile
	var window := {}
	var probe_t := float(int(Time.get_unix_time_from_system()))
	while window.is_empty():
		probe_t += 60.0
		window = profile.eruption_window(probe_t, plume.model.volcano_seed, plume.model.volcano_key)
	var t0 := float(window.start_unix) + at_s
	print("BENCH eruption %s strength %.2f, t = start + %.0f s" % [
		Time.get_datetime_string_from_unix_time(int(window.start_unix)), float(window.strength), at_s])

	var camera := Camera3D.new()
	root.add_child(camera)
	camera.make_current()
	var eye_local := Vector3(eye_m * 0.8, 0.0, eye_m * 0.6)
	eye_local.y = plume._relief(eye_local.x, eye_local.z) + VolcanoPlume.EYE_M
	camera.global_position = plume.to_global(eye_local)
	camera.look_at(plume.to_global(Vector3(0, 3000, 0)), plume.global_basis.y)

	# Warm up 5 s at the start time (the first frame rebuilds every stone slot), then measure.
	var t := t0 - 5.0
	var totals := PackedFloat64Array()
	var dt := 1.0 / fps
	for n in frames + int(5.0 * fps):
		t += dt
		VolcanoPlume.debug_time_shift = t - (VolcanoPlume.clock() - VolcanoPlume.debug_time_shift)
		var started := Time.get_ticks_usec()
		plume._process(dt)
		if t >= t0:
			totals.append((Time.get_ticks_usec() - started) / 1000.0)
		await get_tree().process_frame
	plume._join_model(true)  # the parts below run the model on this thread
	_report("plume._process (main thread)", totals)
	print("BENCH puffs active %d, sent to the shader %s, smoke box visible %s, stones live %s" % [
		plume.model.active_indices.size(), plume._mat.get_shader_parameter("puff_count"), plume._box.visible,
		plume.stones.has_live_stones(t)])

	var model_t := PackedFloat64Array()
	var light_t := PackedFloat64Array()
	var compact_t := PackedFloat64Array()
	var bounds_t := PackedFloat64Array()
	var stones_t := PackedFloat64Array()
	var eye := plume.to_local(camera.global_position)
	var fwd: Vector3 = plume.global_basis.inverse() * -camera.global_basis.z
	for n in 30:
		t += 1.0 / 30.0
		var s := Time.get_ticks_usec()
		plume.model.update(t, 0)
		model_t.append((Time.get_ticks_usec() - s) / 1000.0)
		s = Time.get_ticks_usec()
		plume.model._light(12)
		light_t.append((Time.get_ticks_usec() - s) / 1000.0)
		s = Time.get_ticks_usec()
		plume._update_smoke_bounds()
		bounds_t.append((Time.get_ticks_usec() - s) / 1000.0)
		s = Time.get_ticks_usec()
		plume._compact(eye, fwd, camera.fov)
		compact_t.append((Time.get_ticks_usec() - s) / 1000.0)
		s = Time.get_ticks_usec()
		plume.stones.update(t, eye, eye + Vector3.DOWN * VolcanoPlume.EYE_M, true)
		stones_t.append((Time.get_ticks_usec() - s) / 1000.0)
	var smoke_t := PackedFloat64Array()
	var hash_t := PackedFloat64Array()
	var model := plume.model
	for n in 10:
		var s := Time.get_ticks_usec()
		var step := model.lifetime_s / float(VolcanoPlumeModel.COUNT)
		for i in VolcanoPlumeModel.COUNT:
			var birth := t - float(i) * step
			profile.sample_smoke(birth, t, model.volcano_seed, model.volcano_key, model.dormant)
		smoke_t.append((Time.get_ticks_usec() - s) / 1000.0)
		s = Time.get_ticks_usec()
		for i in VolcanoPlumeModel.COUNT:
			for k in 6: VolcanoPlumeModel._hash(i + k, k)
			VolcanoPlumeModel._noise1(t / 34.0, 41)
			VolcanoPlumeModel._noise1(t / 34.0, 43)
		hash_t.append((Time.get_ticks_usec() - s) / 1000.0)
	_report("220 x sample_smoke", smoke_t)
	_report("220 x (6 hash + 2 noise)", hash_t)
	_report("model.update without light", model_t)
	_report("model._light(12)", light_t)
	_report("_update_smoke_bounds", bounds_t)
	_report("_compact", compact_t)
	_report("stones.update", stones_t)
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
