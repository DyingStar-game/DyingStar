extends RefCounted


## Fixed scene, time, resolution and seed. GPU values include this diagnostic viewport only.
static func run(model: VolcanoPlumeModel, material: ShaderMaterial, camera: Camera3D) -> void:
	var result := {
		"gpu": RenderingServer.get_video_adapter_name(),
		"viewport": str(camera.get_viewport().get_visible_rect().size),
		"render_pixels": str(camera.get_viewport().get_texture().get_size()),
		"cpu_ms": {},
		"gpu_ms": {}
	}
	for state in ["off", "smoke", "eruption"]:
		var profile := VolcanoActivityProfile.new()
		profile.random_enabled = false
		if state != "off":
			var event := VolcanoEvent.new()
			event.start_unix = 850.0
			event.duration_s = 1000.0
			event.eruption_enabled = state == "eruption"
			profile.events.append(event)
		var sample := VolcanoPlumeModel.new()
		sample.profile = profile
		sample.configure_appearance(41, "benchmark")
		sample.sample_wind(1000, Vector2(20, 0))
		for i in 10:
			sample.update(1000.0 + float(i) / 30.0, 12)
		var start := Time.get_ticks_usec()
		for i in 100:
			sample.update(1000.0 + float(i) / 30.0, 12)
		result.cpu_ms[state] = float(Time.get_ticks_usec() - start) / 100000.0
	var viewport := camera.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport, true)
	var puff := model.a[80]
	var centre := Vector3(puff.x, puff.y, puff.z)
	for state in ["outside", "edge", "inside"]:
		var factor := 4.0 if state == "outside" else (1.05 if state == "edge" else 0.25)
		camera.position = centre + Vector3(0.3, 0.1, 1.0).normalized() * puff.w * factor
		camera.look_at(centre)
		material.set_shader_parameter("cam_local", camera.position)
		for i in 20:
			await RenderingServer.frame_post_draw
		var samples: Array[float] = []
		for i in 40:
			await RenderingServer.frame_post_draw
			samples.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport))
		samples.sort()
		result.gpu_ms[state] = samples[samples.size() / 2]
	var file := FileAccess.open("user://volcano_benchmark.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	print("VOLCANO BENCHMARK ", JSON.stringify(result))
