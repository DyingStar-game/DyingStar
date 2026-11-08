extends SceneTree

const LabScene = preload("res://test/lava/lava_lab.tscn")
const SolverScript = preload("res://scenes/planet/lava/viscous_lava_solver.gd")
const SurfaceScript = preload("res://scenes/planet/lava/viscous_lava_surface.gd")
const LavaShader = preload("res://assets/_universe/environment/terrain/viscous_lava.gdshader")
const LavaGroundShader = preload("res://assets/_universe/environment/terrain/viscous_lava_ground.gdshader")
var failures := 0
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + message)
	else:
		print("PASS: ", message)


func _run() -> void:
	var lab = LabScene.instantiate()
	root.add_child(lab)
	await process_frame
	await process_frame
	_check(lab.lava_node.mesh != null and lab.terrain_node.mesh != null, "both terrain and lava submit real meshes")
	lab.source_button.button_pressed = false
	var injected: float = lab.sim.injected_m3
	for frame in 8:
		await process_frame
	_check(lab.sim.injected_m3 == injected, "turning off source stops volume injection")
	lab._toggle_pause()
	var paused_time: float = lab.sim.elapsed_s
	var visual_alpha: float = lab.material.get_shader_parameter("interpolation_alpha")
	for frame in 8:
		await process_frame
	_check(lab.sim.elapsed_s == paused_time and lab.material.get_shader_parameter("interpolation_alpha") == visual_alpha,
			"pause freezes both physics and surface animation")
	for scenario in 3:
		lab.terrain_choice.select(scenario)
		lab.terrain_choice.item_selected.emit(scenario)
		await process_frame
		_check(lab.terrain_kind == scenario and lab.sim.elapsed_s == 0.0 and absf(lab.sim.injected_m3 - 24.0) < 1e-9,
				"terrain scenario resets cleanly: " + str(scenario))
	for quality in 3:
		lab.quality_choice.select(quality)
		lab.quality_choice.item_selected.emit(quality)
		await process_frame
		var expected: int = [32 * 48, 48 * 72, 64 * 96][quality]
		_check(lab.sim.depth.size() == expected and lab.lava_node.mesh != null,
				"quality resize rebuilds compatible meshes: " + str(quality))
	for preset in 3:
		lab.preset_choice.select(preset)
		lab.preset_choice.item_selected.emit(preset)
		await process_frame
		_check(lab.sim.depth.size() == 64 * 96 and lab.sim.diagnostics().volume_m3 > 23.99,
				"rheology preset restarts without losing source accounting: " + str(preset))
	lab.material.set_shader_parameter("thermal_view", true)
	await RenderingServer.frame_post_draw
	_check(root.get_texture().get_image().get_width() > 0, "GPU produces a thermal-view image")
	# Deterministic GPU regression: the same physical state must produce three
	# distinct presentations without rebuilding geometry or changing the solver.
	lab.set_process(false)
	lab._reset()
	var fixed_mesh: RID = lab.lava_node.mesh.get_rid()
	var wet := -1
	for i in lab.sim.depth.size():
		if lab.sim.depth[i] > 0.01:
			wet = i
			lab.sim.depth[i] += 1.0
	lab.surface.publish(lab.sim, 0.1)
	_check(lab.material.get_shader_parameter("interpolation_alpha") == 0.0,
		"a new snapshot cannot flash forward then regress at the next render frame")
	var unchanged: Dictionary = lab.sim.diagnostics()
	var hashes: Array[int] = []
	for alpha in [0.0, 0.5, 1.0]:
		lab.surface.set_interpolation(alpha)
		await process_frame
		await RenderingServer.frame_post_draw
		hashes.append(hash(root.get_texture().get_image().get_data()))
	_check(hashes[0] != hashes[1] and hashes[1] != hashes[2] and hashes[0] != hashes[2],
			"GPU renders genuinely distinct previous, intermediate and current surfaces")
	_check(lab.sim.diagnostics() == unchanged, "visual interpolation preserves physical volume, heat and clock")
	var state_rids: Array[RID] = []
	var phase_rids: Array[RID] = []
	for tick in 12:
		lab.sim.elapsed_s = 100000.0 + tick * 0.1
		lab.sim.velocity[wet] = Vector2(2.0 if tick % 2 == 0 else -1.0, 0.0)
		lab.surface.publish(lab.sim, 0.1)
		var state_texture: Texture2D = lab.material.get_shader_parameter("state_current")
		var phase_texture: Texture2D = lab.material.get_shader_parameter("phase_current")
		if not state_rids.has(state_texture.get_rid()):
			state_rids.append(state_texture.get_rid())
		if not phase_rids.has(phase_texture.get_rid()):
			phase_rids.append(phase_texture.get_rid())
	_check(absf(lab.surface.phases[wet].x - 0.6) < 1e-5, "fissure displacement integrates velocity increments even after long runtimes")
	_check(state_rids.size() == 2 and phase_rids.size() == 2, "GPU texture allocations stay bounded and are reused")
	_check(lab.lava_node.mesh.get_rid() == fixed_mesh and lab.surface.mesh_builds == lab._initial_mesh_builds,
			"simulation never rebuilds or replaces its mesh")
	lab._reset()
	_check(lab.surface.phases[wet] == Vector2.ZERO, "reset clears accumulated visual displacement")
	# Exercise the real frame driver between physics ticks, including pause.
	lab.paused = false
	lab.time_scale = 1.0
	lab._process(0.14)
	var physical_time: float = lab.sim.elapsed_s
	var alpha_before: float = lab.material.get_shader_parameter("interpolation_alpha")
	lab._process(0.02)
	var alpha_after: float = lab.material.get_shader_parameter("interpolation_alpha")
	_check(alpha_after > alpha_before and lab.sim.elapsed_s == physical_time, "display advances on frames with no physics step")
	lab._toggle_pause()
	lab._process(0.02)
	_check(lab.material.get_shader_parameter("interpolation_alpha") == alpha_after, "pause also freezes sub-tick interpolation")
	# Smoke is cosmetic and bounded, including pause, expiry and toggles.
	lab._reset()
	var physical_state: String = lab.sim.state_digest()
	for n in 100: lab.smoke.advance(0.1, lab.sim)
	_check(lab.smoke.active_count > 0 and lab.smoke.active_count <= 96 and lab.smoke.edge_count > 0,
			"lateral smoke uses a bounded edge-only pool")
	_check(lab.sim.state_digest() == physical_state, "smoke cannot change any authoritative bit")
	var smoke_clock: float = lab.smoke.clock
	lab.paused = true
	lab._process(0.1)
	_check(lab.smoke.clock == smoke_clock, "pause freezes smoke as well as lava")
	lab.smoke.set_smoke_enabled(false)
	_check(lab.smoke.active_count == 0 and not lab.smoke.visible, "smoke toggle immediately releases active puffs")
	lab.smoke.set_smoke_enabled(true)
	for n in 100: lab.smoke.advance(0.1, lab.sim)
	lab.smoke._edges.clear()
	lab.smoke._scan_clock = 20.0
	lab.smoke.advance(7.0, lab.sim)
	_check(lab.smoke.active_count == 0, "expired smoke slots disappear instead of looping")
	await _test_terrain_overlay()
	await _test_polar_fade()
	print("LAVA_RENDER_TESTS ", checks - failures, "/", checks, " passed")
	root.remove_child(lab)
	lab.queue_free()
	quit(0 if failures == 0 else 1)


func _test_terrain_overlay() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(128, 128)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 8.0
	viewport.add_child(camera)
	camera.position = Vector3(4, 10, 4)
	camera.look_at(Vector3(4, 0, 4), Vector3.FORWARD)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(8, 8)
	ground.mesh = plane
	var stone := StandardMaterial3D.new()
	stone.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	stone.albedo_color = Color(0.3, 0.4, 0.5)
	ground.material_override = stone
	ground.position = Vector3(4, 1, 4) # Coarse terrain above the physical bed.
	viewport.add_child(ground)
	var sim = SolverScript.new()
	var bed := PackedInt64Array()
	bed.resize(81); bed.fill(0)
	sim.configure_q(9, 9, 1000, bed)
	sim.inject_q(sim.disc_commands(4000, 4000, 1800, 3000, 11500))
	sim.refresh_views()
	var surface = SurfaceScript.new()
	var lava := ShaderMaterial.new()
	lava.shader = LavaShader
	surface.configure(sim, lava)
	var overlay := ShaderMaterial.new()
	overlay.shader = LavaGroundShader
	surface.add_material(overlay, sim.cell_m)
	overlay.set_shader_parameter("patch_from_view", camera.global_transform)
	overlay.set_shader_parameter("thermal_view", true)
	var before: String = sim.state_digest()
	await process_frame
	await RenderingServer.frame_post_draw
	var bare := viewport.get_texture().get_image()
	ground.material_overlay = overlay
	await process_frame
	await RenderingServer.frame_post_draw
	var covered := viewport.get_texture().get_image()
	_check(absf(bare.get_pixel(64, 64).r - covered.get_pixel(64, 64).r) > 0.1,
		"GPU shows lava even when a coarse terrain triangle hides the physical surface")
	_check(bare.get_pixel(8, 8).is_equal_approx(covered.get_pixel(8, 8)),
		"terrain overlay leaves dry ground untouched")
	_check(overlay.get_shader_parameter("state_current") == lava.get_shader_parameter("state_current"),
		"terrain overlay reuses existing state textures without allocating another simulation")
	_check(sim.state_digest() == before, "terrain LOD presentation cannot alter the physical state")
	var shift := Vector3(30000000000.0, 0, 0)
	camera.position += shift
	ground.position += shift
	overlay.set_shader_parameter("patch_from_view", Transform3D(Basis.IDENTITY, -shift) * camera.global_transform)
	await process_frame
	await RenderingServer.frame_post_draw
	var distant := viewport.get_texture().get_image()
	_check(absf(distant.get_pixel(64, 64).r - covered.get_pixel(64, 64).r) < 0.025,
		"terrain lava remains stable at astronomical coordinates")
	var foreground := MeshInstance3D.new()
	foreground.mesh = BoxMesh.new()
	var blue := StandardMaterial3D.new()
	blue.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	blue.albedo_color = Color.BLUE
	foreground.material_override = blue
	foreground.position = shift + Vector3(4, 5, 4)
	viewport.add_child(foreground)
	ground.material_overlay = null
	await process_frame
	await RenderingServer.frame_post_draw
	var clear_object := viewport.get_texture().get_image().get_pixel(64, 64)
	ground.material_overlay = overlay
	await process_frame
	await RenderingServer.frame_post_draw
	_check(clear_object.is_equal_approx(viewport.get_texture().get_image().get_pixel(64, 64)),
		"terrain lava preserves foreground depth occlusion")
	foreground.queue_free()
	plane.flip_faces = true
	stone.cull_mode = BaseMaterial3D.CULL_DISABLED
	ground.material_overlay = null
	await process_frame
	await RenderingServer.frame_post_draw
	var reversed := viewport.get_texture().get_image().get_pixel(64, 64)
	ground.material_overlay = overlay
	await process_frame
	await RenderingServer.frame_post_draw
	_check(absf(reversed.r - viewport.get_texture().get_image().get_pixel(64, 64).r) > 0.1,
		"lava covers reversed HEALPix triangle winding just like the terrain shader")
	ground.position = shift + Vector3(4, -10000, 4)
	camera.far = 20000.0
	ground.material_overlay = null
	await process_frame
	await RenderingServer.frame_post_draw
	var opposite := viewport.get_texture().get_image().get_pixel(64, 64)
	ground.material_overlay = overlay
	await process_frame
	await RenderingServer.frame_post_draw
	_check(opposite.is_equal_approx(viewport.get_texture().get_image().get_pixel(64, 64)),
		"terrain coverage cannot project onto the opposite hemisphere")
	viewport.queue_free()


func _test_polar_fade() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(128, 128)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 30.0
	viewport.add_child(camera)
	camera.position = Vector3(0, 30, 0)
	camera.look_at(Vector3.ZERO, Vector3.FORWARD)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(32, 32)
	ground.mesh = plane
	var stone := StandardMaterial3D.new()
	stone.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	stone.albedo_color = Color(0.3, 0.4, 0.5)
	ground.material_override = stone
	ground.position.y = 1.0
	viewport.add_child(ground)
	var sim = SolverScript.new()
	var edges := PackedInt64Array()
	for r in 13: edges.append(r * 1000)
	var bed := PackedInt64Array(); bed.resize(32 * 12); bed.fill(0)
	sim.configure_polar_q(32, edges, bed)
	sim.cooling_enabled = false
	sim.cleanup_enabled = true
	sim.inject_q(sim.disc_commands(0, 0, 9000, 50000, 12000))
	sim.refresh_views()
	var surface = SurfaceScript.new()
	var mat := ShaderMaterial.new()
	mat.shader = LavaShader
	surface.configure(sim, mat)
	var overlay := ShaderMaterial.new()
	overlay.shader = LavaGroundShader
	surface.add_material(overlay, sim.cell_m)
	overlay.set_shader_parameter("patch_from_view", camera.global_transform)
	ground.material_overlay = overlay
	await process_frame
	await RenderingServer.frame_post_draw
	var hot := viewport.get_texture().get_image()
	_check(hot.get_pixel(64, 64).r > 0.1, "polar crater data produces a real GPU lava lake")
	var a := camera.unproject_position(Vector3(6, 1, 0.3))
	var b := camera.unproject_position(Vector3(6, 1, -0.3))
	_check(hot.get_pixel(int(a.x), int(a.y)).r > 0.1 and hot.get_pixel(int(b.x), int(b.y)).r > 0.1,
		"polar coverage remains continuous across the zero-degree seam")
	while sim.tick < sim.last_source_tick + sim.SOURCE_IDLE_TICKS + 1000: sim.advance_tick(sim.tick + 1)
	surface.publish(sim, 0.1, true); surface.set_interpolation(1.0)
	await process_frame
	await RenderingServer.frame_post_draw
	var black := viewport.get_texture().get_image()
	_check(black.get_pixel(64, 64).r < 0.06, "post-eruption lava becomes black before it disappears")
	while sim.tick < sim.last_source_tick + sim.SOURCE_IDLE_TICKS + sim.FADE_DELAY_TICKS + 900: sim.advance_tick(sim.tick + 1)
	surface.publish(sim, 0.1, true); surface.set_interpolation(1.0)
	await process_frame
	await RenderingServer.frame_post_draw
	var fading := viewport.get_texture().get_image()
	var covered := 0
	var disappeared := 0
	for y in 128:
		for x in 128:
			if black.get_pixel(x, y).r < 0.06:
				covered += 1
				if fading.get_pixel(x, y).r > 0.1: disappeared += 1
	_check(disappeared > covered / 5 and disappeared < covered * 4 / 5,
		"the GPU progressively removes black coverage instead of abruptly hiding the field")
	while not sim.cleanup_complete(): sim.advance_tick(sim.tick + 1)
	for n in 3: sim.advance_tick(sim.tick + 1)
	surface.publish(sim, 0.1, true); surface.set_interpolation(1.0)
	await process_frame
	await RenderingServer.frame_post_draw
	_check(viewport.get_texture().get_image().get_pixel(64, 64).r > 0.1,
		"no stale lava texels remain after cleanup and skipped visual publications")
	viewport.queue_free()
