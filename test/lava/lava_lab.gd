extends Node3D
## Offline laboratory. Launcher stages these exact sources in an ignored,
## minimal Godot project, avoiding multiplayer/C# and global game autoloads.

const Solver = preload("res://scenes/planet/lava/viscous_lava_solver.gd")
const Smoke = preload("res://scenes/planet/lava/lava_edge_smoke.gd")
const Surface = preload("res://scenes/planet/lava/viscous_lava_surface.gd")
const LAVA_SHADER = preload("res://assets/_universe/environment/terrain/viscous_lava.gdshader")
const BASALT_SHADER = preload("res://test/lava/basalt.gdshader")
const DT := 0.1
const MAX_STEPS_PER_FRAME := 8

var sim := Solver.new()
var surface := Surface.new()
var smoke: MultiMeshInstance3D
var _smoke_times: Array[float] = []
var terrain_node: MeshInstance3D
var lava_node: MeshInstance3D
var material: ShaderMaterial
var camera: Camera3D
var stats_label: Label
var status_label: Label
var pause_button: Button
var source_button: CheckButton
var terrain_choice: OptionButton
var quality_choice: OptionButton
var preset_choice: OptionButton
var viscosity_slider: HSlider
var temp_slider: HSlider
var rate_slider: HSlider
var clock_choice: OptionButton
var smoke_toggle: CheckButton
var source_on := true
var paused := false
var time_scale := 4.0
var source_rate := 4.0
var source_temperature := 1150.0
var nx := 32
var nz := 48
var spacing := 2.25
var terrain_kind := 0
var orbit := Vector2(0.68, 0.76)
var distance := 108.0
var target := Vector3(35, 0, 51)
var _accumulator := 0.0
var _hud_clock := 0.0
var _wall_clock := 0.0
var _step_times: Array[float] = []
var _upload_times: Array[float] = []
var _frame_times: Array[float] = []
var _visual_frames := 0
var _interpolated_frames := 0
var _initial_mesh_builds := 0
var _budget_frames := 0
var _capture_path := ""
var _capture_at := 0.0
var _capture_started := false


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("131922"))
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("171e29")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("a0b0c2")
	environment.ambient_light_energy = 0.65
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.environment = environment
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -32, 0)
	sun.light_color = Color("ffddba")
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	add_child(sun)
	camera = Camera3D.new()
	camera.fov = 49.0
	camera.far = 600.0
	add_child(camera)
	terrain_node = MeshInstance3D.new()
	add_child(terrain_node)
	lava_node = MeshInstance3D.new()
	lava_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	material = ShaderMaterial.new()
	material.shader = LAVA_SHADER
	lava_node.material_override = material
	add_child(lava_node)
	smoke = Smoke.new()
	add_child(smoke)
	_build_ui()
	_reset()
	for argument in OS.get_cmdline_user_args():
		if argument == "--no-smoke":
			smoke_toggle.button_pressed = false
		if argument.begins_with("--capture="):
			_capture_path = argument.trim_prefix("--capture=")
			_capture_at = 12.0
		if argument.begins_with("--capture-at="):
			_capture_at = float(argument.trim_prefix("--capture-at="))


func _bed_at(x: float, z: float) -> float:
	var center := 35.0 + sin(z * 0.065) * 7.0
	var bank := pow(absf(x - center) / 19.0, 2.0) * 5.0
	var slope := 13.0 - z * 0.18
	var rough := sin(x * 0.47 + z * 0.17) * cos(z * 0.39) * 0.24
	if terrain_kind == 1:
		# Basin bounded by a sill: lava must fill it before overflowing.
		slope += 4.5 * exp(-pow((z - 66.0) / 5.0, 2.0))
	elif terrain_kind == 2:
		# Continuous ridge across the channel; no carving through it.
		slope += 7.0 * exp(-pow((z - 48.0) / 2.5, 2.0))
	else:
		# An island divides the advancing front into two lobes.
		bank += 6.0 * exp(-pow((x - 35.0) / 5.0, 2.0) - pow((z - 47.0) / 9.0, 2.0))
	return slope + bank + rough


func _reset() -> void:
	var bed := PackedFloat64Array()
	bed.resize(nx * nz)
	for z in nz:
		for x in nx:
			bed[z * nx + x] = _bed_at(x * spacing, z * spacing)
	sim.configure(nx, nz, spacing, bed)
	_accumulator = 0.0
	_budget_frames = 0
	_step_times.clear()
	_upload_times.clear()
	_smoke_times.clear()
	smoke.reset()
	_frame_times.clear()
	_visual_frames = 0
	_interpolated_frames = 0
	# A small initial discharge makes the vent visible immediately; accounted
	# for in injected_m3. The remaining evolution is the actual solver.
	sim.inject_disc(Vector2(37.0, 9.0), 3.0, 24.0, source_temperature)
	_build_terrain()
	_build_lava_surface()
	_update_camera()
	_update_hud()


func _build_terrain() -> void:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for z in nz:
		for x in nx:
			var px := x * spacing
			var pz := z * spacing
			vertices.append(Vector3(px, sim.bed[z * nx + x], pz))
			normals.append(Vector3(_bed_at(px - 0.25, pz) - _bed_at(px + 0.25, pz), 0.5,
				_bed_at(px, pz - 0.25) - _bed_at(px, pz + 0.25)).normalized())
			var variation := 0.60 + 0.3 * sin(px * 1.27 + pz * 0.33) * cos(pz * 0.8)
			colors.append(Color(0.16, 0.17, 0.18) * variation)
	for z in nz - 1:
		for x in nx - 1:
			var i := z * nx + x
			indices.append_array(PackedInt32Array([i, i + 1, i + nx, i + 1, i + nx + 1, i + nx]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	terrain_node.mesh = mesh
	var rock := ShaderMaterial.new()
	rock.shader = BASALT_SHADER
	terrain_node.material_override = rock


func _build_lava_surface() -> void:
	surface.configure(sim, material)
	lava_node.mesh = surface.mesh
	lava_node.custom_aabb = surface.bounds
	_initial_mesh_builds = surface.mesh_builds


func _process(delta: float) -> void:
	_wall_clock += delta
	_frame_times.append(delta * 1000.0)
	if _frame_times.size() > 1200:
		_frame_times.pop_front()
	if not paused:
		_accumulator += delta * time_scale # Never discard authoritative ticks to meet a render budget.
		var steps := 0
		var frame_start := Time.get_ticks_usec()
		while _accumulator >= DT and steps < MAX_STEPS_PER_FRAME:
			var start := Time.get_ticks_usec()
			var commands := PackedInt64Array()
			if source_on and source_rate > 0.0:
				commands = sim.disc_commands(37000, 9000, 3000, roundi(source_rate * 100.0), roundi(source_temperature * 10.0))
			if not sim.advance_tick(sim.tick + 1, commands):
				paused = true
				push_error("Lava tick rejected: source capacity or invalid canonical command")
				break
			_step_times.append((Time.get_ticks_usec() - start) / 1000.0)
			if _step_times.size() > 480:
				_step_times.pop_front()
			var upload_start := Time.get_ticks_usec()
			surface.publish(sim, DT, true)
			lava_node.custom_aabb = surface.bounds
			_upload_times.append((Time.get_ticks_usec() - upload_start) / 1000.0)
			if _upload_times.size() > 480:
				_upload_times.pop_front()
			_accumulator -= DT
			steps += 1
			if Time.get_ticks_usec() - frame_start > 6000:
				_budget_frames += 1
				break
		var alpha := clampf(_accumulator / DT, 0.0, 1.0)
		surface.set_interpolation(alpha)
		var smoke_start := Time.get_ticks_usec()
		smoke.advance(delta, sim)
		_smoke_times.append((Time.get_ticks_usec() - smoke_start) / 1000.0)
		if _smoke_times.size() > 1200:
			_smoke_times.pop_front()
		_visual_frames += 1
		if surface.publications > 0 and alpha > 0.001 and alpha < 0.999:
			_interpolated_frames += 1
	_hud_clock += delta
	if _hud_clock > 0.4:
		_hud_clock = 0.0
		_update_hud()
	if _capture_at > 0.0 and _wall_clock >= _capture_at and not _capture_started:
		_capture_started = true
		_capture()


func _capture() -> void:
	await RenderingServer.frame_post_draw
	var capture_error := get_viewport().get_texture().get_image().save_png(_capture_path)
	var report := sim.diagnostics()
	report.merge({"solver_ms_p95": _percentile(_step_times, 0.95),
		"smoke_ms_p95": _percentile(_smoke_times, 0.95), "smoke_ms_max": _percentile(_smoke_times, 1.0),
		"smoke_enabled": smoke.smoke_enabled, "smoke_active": smoke.active_count,
		"state_sha256": sim.state_digest(), "backlog_ticks": int(_accumulator / DT),
		"upload_ms_p95": _percentile(_upload_times, 0.95),
		"frame_ms_p50": _percentile(_frame_times, 0.5), "frame_ms_p95": _percentile(_frame_times, 0.95),
		"frame_ms_p99": _percentile(_frame_times, 0.99),
		"visual_frames": _visual_frames, "interpolated_frames": _interpolated_frames,
		"mesh_rebuilds_during_simulation": surface.mesh_builds - _initial_mesh_builds,
		"state_publications": surface.publications, "fps": Engine.get_frames_per_second(),
		"budget_frames": _budget_frames, "grid": [nx, nz], "capture_error": capture_error})
	var file := FileAccess.open(_capture_path.get_basename() + ".json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(report, "\t"))
	print("LAVA_CAPTURE ", JSON.stringify(report))
	get_tree().quit(0 if capture_error == OK else 1)


func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[mini(sorted.size() - 1, int(sorted.size() * fraction))]


func _update_hud() -> void:
	var d := sim.diagnostics()
	stats_label.text = "%.0f s simulées  ·  %d FPS\n%d × %d cellules  ·  %d occupées\nVolume %.1f m³  ·  apport %.1f m³\nÉcart de volume : %.6f m³\nCalcul P95 %.2f ms  ·  transfert P95 %.2f ms\nÉpaisseur max. %.2f m  ·  %d cellules figées" % [
		sim.elapsed_s, Engine.get_frames_per_second(), nx, nz, d.wet_cells,
		d.volume_m3, d.injected_m3, d.volume_m3 - d.injected_m3,
		_percentile(_step_times, 0.95), _percentile(_upload_times, 0.95), d.max_depth_m, d.frozen_cells]
	status_label.text = "PAUSE" if paused else ("ÉMISSION ACTIVE" if source_on else "REFROIDISSEMENT · source coupée")


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(22, 22)
	panel.custom_minimum_size = Vector2(330, 0)
	layer.add_child(panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.045, 0.065, 0.94)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	style.corner_radius_top_left = 10
	style.corner_radius_bottom_right = 10
	panel.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	panel.add_child(box)
	_label(box, "DYING STAR / LAVE", 22, Color("ffb45e"))
	_label(box, "LABORATOIRE · FLUIDE VISQUEUX", 12, Color("93a7bd"))
	status_label = _label(box, "", 13, Color("ffd59a"))
	terrain_choice = _choice(box, "Relief", ["Vallée · îlot et bifurcation", "Bassin · remplissage et débordement", "Barrage · accumulation"])
	terrain_choice.item_selected.connect(func(index: int): terrain_kind = index; _reset())
	preset_choice = _choice(box, "Rhéologie", ["Basalte · 1 800 Pa·s", "Très visqueuse · 18 000 Pa·s", "Lave refroidie · 1 030 °C"])
	preset_choice.item_selected.connect(_preset)
	viscosity_slider = _slider(box, "Viscosité à 1 150 °C · Pa·s", 2.0, 5.0, log(1800.0) / log(10.0), 0.001, true)
	viscosity_slider.value_changed.connect(func(value: float): sim.viscosity_pa_s = pow(10.0, value))
	temp_slider = _slider(box, "Température à la source · °C", 960, 1250, 1150, 5)
	temp_slider.value_changed.connect(func(value: float): source_temperature = value)
	rate_slider = _slider(box, "Débit de lave · m³/s", 0, 16, 4, 0.5)
	rate_slider.value_changed.connect(func(value: float): source_rate = value)
	quality_choice = _choice(box, "Grille physique commune client / serveur", ["Éco · 32 × 48", "Équilibré · 48 × 72", "Fin · 64 × 96"])
	quality_choice.select(0)
	quality_choice.item_selected.connect(func(index: int):
		nx = [32, 48, 64][index]; nz = [48, 72, 96][index]; spacing = 72.0 / nx; _reset())
	clock_choice = _choice(box, "Temps (ralenti automatiquement si budget atteint)", ["Temps réel ×1", "Accéléré ×4", "Accéléré ×12"])
	clock_choice.select(1)
	clock_choice.item_selected.connect(func(index: int): time_scale = [1.0, 4.0, 12.0][index])
	source_button = CheckButton.new()
	source_button.text = "Alimenter la coulée"
	source_button.button_pressed = true
	source_button.toggled.connect(func(enabled: bool): source_on = enabled)
	box.add_child(source_button)
	var visual_options := HBoxContainer.new()
	box.add_child(visual_options)
	var thermal := CheckButton.new()
	thermal.text = "Thermique"
	thermal.toggled.connect(func(enabled: bool): material.set_shader_parameter("thermal_view", enabled))
	visual_options.add_child(thermal)
	smoke_toggle = CheckButton.new()
	smoke_toggle.text = "Fumée latérale"
	smoke_toggle.button_pressed = true
	smoke_toggle.toggled.connect(smoke.set_smoke_enabled)
	visual_options.add_child(smoke_toggle)
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	pause_button = Button.new()
	pause_button.text = "Pause [Espace]"
	pause_button.pressed.connect(_toggle_pause)
	buttons.add_child(pause_button)
	var reset := Button.new()
	reset.text = "Repartir [R]"
	reset.pressed.connect(_reset)
	buttons.add_child(reset)
	stats_label = _label(box, "", 13, Color("bdcbd9"))
	_label(box, "Glisser dans la vue : orbite · molette : zoom\nEspace : pause · R : repartir · L : source\nModèle local 2,5D · sans éclaboussures", 12, Color("8698ab"))


func _label(parent: Node, text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


func _choice(parent: Node, title: String, items: Array) -> OptionButton:
	_label(parent, title, 12, Color("a9b9cc"))
	var choice := OptionButton.new()
	for item in items:
		choice.add_item(item)
	parent.add_child(choice)
	return choice


func _slider(parent: Node, title: String, low: float, high: float, initial: float, increment: float, logarithmic: bool = false) -> HSlider:
	var initial_display := pow(10.0, initial) if logarithmic else initial
	var label := _label(parent, title + "  [%.0f]" % initial_display, 12, Color("a9b9cc"))
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = increment
	slider.value = initial
	slider.custom_minimum_size.y = 18
	slider.value_changed.connect(func(value: float):
		var display := pow(10.0, value) if logarithmic else value
		label.text = title + "  [%.1f]" % display)
	parent.add_child(slider)
	return slider


func _preset(index: int) -> void:
	sim.viscosity_pa_s = 18000.0 if index == 1 else 1800.0
	sim.yield_pa = 350.0 if index == 1 else 120.0
	source_temperature = 1030.0 if index == 2 else 1150.0
	viscosity_slider.value = log(sim.viscosity_pa_s) / log(10.0)
	temp_slider.value = source_temperature
	_reset()


func _toggle_pause() -> void:
	paused = not paused
	pause_button.text = "Reprendre [Espace]" if paused else "Pause [Espace]"
	_update_hud()


func _update_camera() -> void:
	camera.position = target + Vector3(sin(orbit.x) * cos(orbit.y), sin(orbit.y), cos(orbit.x) * cos(orbit.y)) * distance
	camera.look_at(target)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		orbit.x -= event.relative.x * 0.005
		orbit.y = clampf(orbit.y + event.relative.y * 0.004, 0.15, 1.5)
		_update_camera()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(18.0, distance * 0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = minf(240.0, distance * 1.1)
		_update_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_toggle_pause()
		elif event.keycode == KEY_R:
			_reset()
		elif event.keycode == KEY_L:
			source_button.button_pressed = not source_on
