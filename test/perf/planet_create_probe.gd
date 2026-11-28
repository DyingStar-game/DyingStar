extends Node
## What making a body costs the client (spawn:tarsis_3, 3.3 s in one frame at an arrival, 2026-11-28): its
## scene instanced and entering the tree, with ClientPerf's pb:* / pl:* scopes printed. Twice, the second
## after freeing the first (what a cache keeps). Windowed or headless.
##   <godot> [--headless] --path . res://test/perf/planet_create_probe.tscn [-- body=res://scenes/systems/tarsis/tarsis_3.tscn prewarm]

var _body := "res://scenes/systems/tarsis/tarsis_3.tscn"


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("body="):
			_body = a.get_slice("=", 1)
	_run.call_deferred()


func _ms(t: int) -> float:
	return (Time.get_ticks_usec() - t) / 1000.0


var _kept: Array = []


func _run() -> void:
	await get_tree().process_frame
	# prewarm: the shaders the warm-up compiles by use (Warmup.BY_USE_SHADERS), compiled and kept first.
	if OS.get_cmdline_user_args().has("prewarm"):
		for path: String in Warmup.BY_USE_SHADERS:
			var shader := load(path) as Shader
			_kept.append(shader)
			var material := ShaderMaterial.new()
			material.shader = shader
			var rect := ColorRect.new()
			rect.visible = false
			rect.material = material
			add_child(rect)
			rect.queue_free()
		for path: String in [RailwaySettings.MODULE_PATH]:
			_kept.append(load(path))
		await get_tree().process_frame
	for round_k in 2:
		var t := Time.get_ticks_usec()
		var scene := load(_body) as PackedScene
		var load_ms := _ms(t)
		t = Time.get_ticks_usec()
		var planet := scene.instantiate()
		var inst_ms := _ms(t)
		var before: Dictionary = (ClientPerf.get("_session_usec") as Dictionary).duplicate()
		t = Time.get_ticks_usec()
		add_child(planet)
		var enter_ms := _ms(t)
		var after: Dictionary = ClientPerf.get("_session_usec")
		var parts: Array = []
		for k: String in after:
			if k.begins_with("pl:") or k.begins_with("pb:"):
				var d := int(after[k]) - int(before.get(k, 0))
				if d > 1000:
					parts.append([d, k])
		parts.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) > int(b[0]))
		var text := PackedStringArray()
		for p: Array in parts:
			text.append("%s=%.0f" % [p[1], p[0] / 1000.0])
		print("[PlanetCreate] round %d: load %.0f ms, instantiate %.0f ms, enter %.0f ms | %s" % [round_k,
				load_ms, inst_ms, enter_ms, " ".join(text)])
		var data: Object = planet.get("planet_data")
		if data != null:
			var keys: Array = (data.get("_grade_plans") as Dictionary).keys()
			keys.sort()
			print("[PlanetCreate] grade: %d spans, %d plans, keys hash %s" % [(data.get("_grade_spans") as Array).size(),
					keys.size(), str(keys).md5_text().substr(0, 8)])
			if round_k == 0:
				for step: String in ["get_whole_roads", "grade_bake_key", "bridge_bake_key", "crack_exclusion_fingerprint"]:
					var ts := Time.get_ticks_usec()
					var out: Variant = data.call(step)
					print("[PlanetCreate]   %s: %.1f ms (%s)" % [step, _ms(ts),
							str(out.size()) + " roads" if out is Array else "key"])
		planet.queue_free()
		for k in 5:
			await get_tree().process_frame
	get_tree().quit()
