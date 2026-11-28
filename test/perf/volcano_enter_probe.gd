extends Node3D
## What each volcano's nodes cost entering the tree (vol:enter), run WITH a window: shaders and pipelines are
## the GPU's, which headless never compiles. Every volcano of tarsis_3 that wants a node, built and entered in
## turn, a few frames apart, with or without its lake and glow; its lake alone; then a second time (warm).
##   <godot> --path . res://test/perf/volcano_enter_probe.tscn

var _cam: Camera3D
var _kept: Array[Node] = []


func _ready() -> void:
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	_run.call_deferred()


func _ms(t: int) -> float:
	return (Time.get_ticks_usec() - t) / 1000.0


func _run() -> void:
	var data: PlanetData = SystemScenes.root_properties("res://scenes/systems/tarsis/tarsis_3.tscn").planet_data.duplicate(true)
	data.apply_chunk_manifest()
	data.connect_tile_service()
	data.warm_mountains()
	var profile := VolcanoActivityProfile.for_planet(data.planet_name)
	var seen := {}
	var volcanoes: Array = []
	for ip in 12:
		for v: VolcanoRelief.Volcano in data.get_chunk_volcanoes(1, ip):
			var key := VolcanoFeatures.key_of(v)
			if not seen.has(key) and VolcanoFeatures.wants_node(v, profile):
				seen[key] = true
				volcanoes.append(v)
	print("[VolcEnter] %d volcanoes want a node" % volcanoes.size())
	# A few frames first: the first one drawn compiles the renderer's own pipelines, volcano or not.
	for k in 30:
		await get_tree().process_frame
	var t0 := Time.get_ticks_usec()
	await get_tree().process_frame
	print("[VolcEnter] an empty frame: %.1f ms" % _ms(t0))
	# warm=<file.gdshader>: that shader drawn hidden first (as the warm-up would), its frames timed.
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("warm="):
			var shader := load("res://assets/_universe/environment/terrain/volcano/" + arg.get_slice("=", 1)) as Shader
			var mat := ShaderMaterial.new()
			mat.shader = shader
			var shown := MeshInstance3D.new()
			shown.mesh = BoxMesh.new()
			shown.material_override = mat
			if shader.get_mode() == Shader.MODE_PARTICLES:
				var gp := GPUParticles3D.new()
				gp.process_material = mat
				gp.draw_pass_1 = QuadMesh.new()
				gp.amount = 8
				add_child(gp)
			else:
				add_child(shown)
			var worst := 0.0
			for k in 20:
				var tw := Time.get_ticks_usec()
				await get_tree().process_frame
				worst = maxf(worst, _ms(tw))
			print("[VolcEnter] warmed %s: worst frame %.1f ms" % [arg.get_slice("=", 1), worst])
	for pass_k in 1:
		for v: VolcanoRelief.Volcano in volcanoes.slice(0, 8):
			var t := Time.get_ticks_usec()
			var node := VolcanoFeatures.build(data, v)
			var build_ms := _ms(t)
			var parts := PackedStringArray()
			for c in node.get_children():
				parts.append(str(c.name))
			# Out of the volcano's frame: the probe's own, at the origin, the camera on it.
			node.position = Vector3.ZERO
			var before: Dictionary = (ClientPerf.get("_session_usec") as Dictionary).duplicate()
			if OS.get_cmdline_user_args().has("noenter"):
				node.free()
				node = Node3D.new()
			t = Time.get_ticks_usec()
			add_child(node)
			var enter_ms := _ms(t)
			# strip=<Name,...>: those parts freed before the first frame draws them.
			for arg: String in OS.get_cmdline_user_args():
				if arg.begins_with("particles="):
					for gp in node.find_children("*", "GPUParticles3D", true, false):
						match arg.get_slice("=", 1):
							"nopreprocess":
								(gp as GPUParticles3D).preprocess = 0.0
							"noemit":
								(gp as GPUParticles3D).emitting = false
						print("[VolcEnter] particles %s: amount %d preprocess %.1f lifetime %.1f fixed_fps %d" % [
								gp.get_path(), gp.amount, gp.preprocess, gp.lifetime, gp.fixed_fps])
				if arg.begins_with("noproc="):
					var plume := node.get_node("Plume") as VolcanoPlume
					match arg.get_slice("=", 1):
						"plume":
							plume.set_process(false)
						"sound":
							var snd := node.get_node("Sound")
							snd.set_process(false)
							snd.set_physics_process(false)
						"stones":
							plume.stones.set_process(false)
							plume.stones.set_physics_process(false)
				if arg.begins_with("strip="):
					for part_name: String in arg.get_slice("=", 1).split(","):
						for found in node.find_children(part_name, "", true, false):
							found.get_parent().remove_child(found)
							found.queue_free()
			var scopes := PackedStringArray()
			var after: Dictionary = ClientPerf.get("_session_usec")
			for k: String in after:
				var d := int(after[k]) - int(before.get(k, 0))
				if d > 200 and (k.begins_with("plume:") or k.begins_with("snd:")):
					scopes.append("%s=%.1f" % [k, d / 1000.0])
			parts.append(" ".join(scopes))
			t = Time.get_ticks_usec()
			await get_tree().process_frame
			var frame_ms := _ms(t)
			t = Time.get_ticks_usec()
			await get_tree().process_frame
			var frame2_ms := _ms(t)
			print("[VolcEnter] pass %d %s %s lake=%s: build %.1f, enter %.1f, next frames %.1f %.1f ms [%s]" % [
					pass_k, VolcanoFeatures.key_of(v), v.activity, str(v.lake), build_ms, enter_ms, frame_ms, frame2_ms,
					", ".join(parts)])
			_kept.append(node)  # kept, as the game keeps them: their shaders stay loaded
			node.visible = false
	if OS.get_cmdline_user_args().has("release"):
		VolcanoPlume._billow = null
		VolcanoStoneField._shared_cracks = null
	get_tree().quit()
