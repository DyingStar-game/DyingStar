extends Node3D
## Fixed close-up regression: render outside, inside and at the edge of dense smoke.
var _camera: Camera3D
var _material: ShaderMaterial
var _model := VolcanoPlumeModel.new()


func _ready() -> void:
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.22, 0.32, 0.45)
	add_child(environment)
	_camera = Camera3D.new()
	_camera.near = 0.05
	_camera.far = 200000.0
	add_child(_camera)
	_model.configure_appearance(41, "closeup")
	_model.sample_wind(1000.0, Vector2(20, 0))
	_model.update(1000.0, VolcanoPlumeModel.COUNT)
	_material = ShaderMaterial.new()
	_material.shader = load(VolcanoPlume.SHADER_DIR + "plume.gdshader")
	_material.set_shader_parameter("billow_tex", VolcanoPlume._billow_texture())
	_material.set_shader_parameter("puff_a", _model.a)
	_material.set_shader_parameter("puff_b", _model.b)
	_material.set_shader_parameter("puff_c", _model.c)
	_material.set_shader_parameter("sun_dir", Vector3(0.4, 0.7, 0.5).normalized())
	_material.set_shader_parameter("sun_color", Vector3(1.9, 1.8, 1.65))
	_material.set_shader_parameter("sky_color", Vector3(0.6, 0.66, 0.75))
	_material.set_shader_parameter("ground_color", Vector3(0.3, 0.27, 0.25))
	_material.set_shader_parameter("haze_color", Vector3(0.4, 0.5, 0.65))
	_material.set_shader_parameter("glow", 0.0)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(80000, 40000, 80000)
	var volume := MeshInstance3D.new()
	volume.mesh = mesh
	volume.material_override = _material
	volume.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(volume)
	await get_tree().create_timer(1.0).timeout
	if "--stone-cleanup" in OS.get_cmdline_user_args():
		var ok := await _test_stone_cleanup()
		get_tree().quit(0 if ok else 1)
		return
	if "--benchmark" in OS.get_cmdline_user_args():
		await preload("res://test/volcano/volcano_benchmark.gd").run(_model, _material, _camera)
		get_tree().quit()
		return
	if "--lifecycle" in OS.get_cmdline_user_args():
		await _capture_lifecycle()
		get_tree().quit()
		return
	var failures := 0
	var max_overlap := 0
	var reversed_a := _model.a.duplicate()
	var reversed_b := _model.b.duplicate()
	var reversed_c := _model.c.duplicate()
	reversed_a.reverse()
	reversed_b.reverse()
	reversed_c.reverse()
	var puff := _model.a[80]
	var centre := Vector3(puff.x, puff.y, puff.z)
	for name in ["outside", "edge", "inside"]:
		var factor := 4.0 if name == "outside" else (1.05 if name == "edge" else 0.25)
		_camera.position = centre + Vector3(0.3, 0.1, 1.0).normalized() * puff.w * factor
		_camera.look_at(centre)
		_material.set_shader_parameter("cam_local", _camera.position)
		_material.set_shader_parameter("puff_a", _model.a)
		_material.set_shader_parameter("puff_b", _model.b)
		_material.set_shader_parameter("puff_c", _model.c)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var original := get_viewport().get_texture().get_image()
		original.save_png("user://plume_closeup_%s.png" % name)
		original.convert(Image.FORMAT_RGB8)
		_material.set_shader_parameter("puff_a", reversed_a)
		_material.set_shader_parameter("puff_b", reversed_b)
		_material.set_shader_parameter("puff_c", reversed_c)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var reversed := get_viewport().get_texture().get_image()
		reversed.convert(Image.FORMAT_RGB8)
		var first := original.get_data()
		var second := reversed.get_data()
		var different := 0
		for i in first.size():
			if absi(int(first[i]) - int(second[i])) > 8:
				different += 1
		var fraction := float(different) / float(first.size())
		if fraction > 0.005:
			failures += 1
		var overlap := 0
		var ray := -_camera.basis.z
		for i in _model.a.size():
			var sphere := _model.a[i]
			var offset := _camera.position - Vector3(sphere.x, sphere.y, sphere.z)
			var along := offset.dot(ray)
			if _model.b[i].x > 0.03 and (offset - ray * along).length_squared() < sphere.w * sphere.w:
				overlap += 1
		max_overlap = maxi(max_overlap, overlap)
		print("VOLCANO CLOSEUP %s: %d overlapping puffs, reversed-order pixel difference %.4f%%" % [name, overlap, fraction * 100.0])
	if max_overlap <= 32:
		failures += 1
		push_error("Closeup did not exercise the former 32-puff limit")
	print("VOLCANO CLOSEUP: %s, outside/edge/inside and overlap order checked" % ("PASS" if failures == 0 else "FAIL"))
	get_tree().quit(0 if failures == 0 else 1)


func _capture_lifecycle() -> void:
	var profile := VolcanoActivityProfile.new()
	profile.random_enabled = false
	profile.dissipation_s = 60.0
	var event := VolcanoEvent.new()
	event.start_unix = 10000.0
	event.duration_s = 180.0
	event.ramp_up_s = 30.0
	event.ramp_down_s = 20.0
	event.strength = 1.6
	event.eruption_enabled = false
	profile.events.append(event)
	_model.profile = profile
	_camera.position = Vector3(5000, 2000, 7000)
	_camera.look_at(Vector3(500, 2200, 0))
	_material.set_shader_parameter("cam_local", _camera.position)
	var stages := {"off": 9999.0, "growing": 10015.0, "full": 10090.0, "dissipating": 10181.0, "off_again": 10241.0}
	for stage: String in stages:
		var when: float = stages[stage]
		_model.sample_wind(when, Vector2(20, 0))
		_model.update(when, VolcanoPlumeModel.COUNT)
		_material.set_shader_parameter("puff_a", _model.a)
		_material.set_shader_parameter("puff_b", _model.b)
		_material.set_shader_parameter("puff_c", _model.c)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://plume_lifecycle_%s.png" % stage)
		print("VOLCANO LIFECYCLE RENDER %s: %s" % [stage, _model.state_label(when)])


func _test_stone_cleanup() -> bool:
	_material.set_shader_parameter("puff_count", 0)
	_model.profile = VolcanoActivityProfile.new()
	_model.profile.random_enabled = false
	_camera.position = Vector3(0, 4, 18)
	_camera.look_at(Vector3(0, 4, 0))
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -25, 0)
	add_child(light)
	var field := VolcanoStoneField.new(_model, func(_x: float, _z: float) -> float: return 0.0)
	field.rebuild_on_jump = false
	add_child(field)
	field.update(1000, _camera.position, Vector3.ZERO, false)
	var velocity := Vector3(1, 16, 0)
	field._write(0, velocity, 1000, 1.0, 3.2, 0.5, 1.0)
	field._register(0, velocity, 1000, 1.0, 3.2, 1000)
	var start := Time.get_ticks_msec()
	var captured := false
	while Time.get_ticks_msec() - start < 4000:
		var elapsed := float(Time.get_ticks_msec() - start) / 1000.0
		field.update(1000 + elapsed, _camera.position, Vector3.ZERO, false)
		if elapsed > 0.3 and not captured:
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("user://volcano_stone_cleanup.png")
			captured = true
		await get_tree().process_frame
	var promoted := field.promoted_total > 0
	field.suspend()
	await get_tree().process_frame
	await get_tree().process_frame
	var ok := promoted and field.props_alive() == 0 and field._dust_nodes.is_empty()
	ok = ok and field.get_child_count() == 2 and not field.is_physics_processing()
	print(
		(
			"VOLCANO STONE RENDER CLEANUP: %s (flight, promotion, impact, suspension, no remaining transient nodes)"
			% ("PASS" if ok else "FAIL")
		)
	)
	field.free()
	return ok
