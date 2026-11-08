extends Node
## Offline authority bridge for the real game world. Canonical terrain and
## source commands originate in the SERVER PlanetTerrain, then the CLIENT
## PlanetTerrain consumes the same packet/tick. No per-client resampling.

const TickJob = preload("res://scenes/planet/lava/lava_tick_job.gd")
const Builder = preload("res://scenes/planet/lava/lava_planet_patch.gd")
var view: Node
var world: Node
var _authority: Node3D
var _replica: Node3D
var _packet := {}
var _key := ""
var _selection := -1
var _loading := false
var _source_paused := false
var _accumulator := 0.0
var _duration_s := 2400.0
var _event_start_tick := 0
var _time_rate := 1
var _fast_forward_s := 0.0
var _preview: VolcanoEvent
var _profile: VolcanoActivityProfile
var _label: Label
var _capture_file := ""
var _capture_clock := 0.0
var _captured := false
var _times: Array[float] = []
var _jobs: Array[RefCounted] = []
var _tasks: Array[int] = []
var _physics_times: Array[float] = []
var _display_tick := 0
var _display_injected := 0
var _display_removed := 0
var _restart_requested := false
var _comparisons := 0
var _mismatches := 0


func _ready() -> void:
	_authority = world.collision_terrain.lava_runtime
	_replica = world.body.planet_terrain.lava_runtime
	var layer := CanvasLayer.new()
	layer.layer = 55
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(14, 310)
	_label.add_theme_font_size_override("font_size", 15)
	_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.5))
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_label)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--lava-capture="):
			_capture_file = argument.trim_prefix("--lava-capture=")
		elif argument.begins_with("--lava-duration="):
			_duration_s = clampf(float(argument.trim_prefix("--lava-duration=")), 10.0, 604800.0)
		elif argument.begins_with("--lava-fast-forward="):
			_fast_forward_s = clampf(float(argument.trim_prefix("--lava-fast-forward=")), 0.0, 604800.0)
	_select_current.call_deferred()


func _select_current() -> void:
	if _loading or view.active.is_empty():
		return
	_join_jobs()
	_jobs.clear()
	_restart_requested = false
	_loading = true
	_label.text = "Lave : préparation de la zone sur le relief réel..."
	await get_tree().process_frame
	if not _key.is_empty():
		_authority.remove_patch(_key)
		_replica.remove_patch(_key)
	_remove_preview()
	_selection = view.current
	var volcano: VolcanoRelief.Volcano = view.active[_selection]
	while not Builder.terrain_ready(world.collision_terrain.planet_data, volcano):
		_label.text = "Lave : attente des tuiles de terrain canoniques du volcan..."
		await get_tree().create_timer(0.2).timeout
		if world._closing:
			return
	_packet = Builder.build(world.collision_terrain.planet_data, volcano)
	if _packet.is_empty():
		_key = ""
		_loading = false
		_label.text = "Relief trop escarpé pour cette zone locale. V : autre volcan."
		return
	_key = str(_packet.key)
	_profile = VolcanoActivityProfile.for_planet(world.body.planet_data.planet_name)
	_event_start_tick = 0
	_start_preview()
	_source_paused = false
	if not _authority.install_patch(_packet):
		push_error("Cannot install authoritative lava patch")
		_loading = false
		return
	# Optional command-line time lapse; never seed a deposit before an eruption.
	# A late join receives the current canonical state, not resampled terrain.
	var server = _authority.patches[_key].solver
	for n in roundi(_fast_forward_s * 10.0):
		var next: int = server.tick + 1
		if not _authority.advance_patch(_key, next, _commands(next)):
			push_error("Lava time-lapse tick rejected")
			break
		if n % 80 == 0:
			await get_tree().process_frame
	_packet.checkpoint = server.checkpoint()
	if not _replica.install_patch(_packet):
		push_error("Cannot install canonical client lava patch")
		_loading = false
		return
	_accumulator = 0.0
	_times.clear()
	_physics_times.clear()
	_display_tick = server.tick
	_display_injected = server.injected_q
	_display_removed = server.removed_q
	_capture_clock = 0.0
	_loading = false
	_sync_event_visual()
	_compare()
	print("[LAVA GAME] ", _key, " grid=", server.width, "x", server.height,
		" cell=", server.cell_mm, "mm gravity=", server.gravity_milli, " build_ms=", _packet.build_ms)
	focus_patch()


func _commands(next: int) -> PackedInt64Array:
	var server = _authority.patches[_key].solver
	# Same integer plan as the game's eruptions (LavaPlanetPatch.eruption_commands), counted from K.
	if _source_paused or _preview == null or not _preview.eruption_enabled:
		return PackedInt64Array()
	var plan := Builder.eruption_plan({"start_unix": 0.0, "length_s": _duration_s, "strength": _preview.strength,
		"ramp_up_s": _preview.ramp_up_s, "ramp_down_s": _preview.ramp_down_s}, _packet)
	return Builder.eruption_commands(server, _packet, plan, next - _event_start_tick)


func _process(delta: float) -> void:
	if _loading or world._closing: return
	if view.current != _selection:
		_select_current()
		return
	if _key.is_empty() or not _replica.patches.has(_key): return
	_accumulator += delta * _time_rate
	_capture_clock += delta
	if not _tasks.is_empty():
		for task in _tasks:
			if not WorkerThreadPool.is_task_completed(task): return
		_join_jobs()
		for job in _jobs:
			if not job.ok:
				push_error("Lava worker rejected a canonical tick")
				set_process(false)
				return
		var cpu := 0
		for job in _jobs: cpu += job.cpu_usec
		_physics_times.append(cpu / 1000.0)
		if _physics_times.size() > 600: _physics_times.pop_front()
		var started := Time.get_ticks_usec()
		_replica.publish_patch(_key)
		_times.append((Time.get_ticks_usec() - started) / 1000.0)
		if _times.size() > 600: _times.pop_front()
		var server = _authority.patches[_key].solver
		_display_tick = server.tick
		_display_injected = server.injected_q
		_display_removed = server.removed_q
		if server.tick % 50 == 0: _compare()
		_jobs.clear()
	if _restart_requested:
		_restart_requested = false
		_start_preview()
	_sync_event_visual()
	var age := maxf(0.0, (_display_tick - _event_start_tick) / 10.0)
	var phase := "éruption" if age < _duration_s else ("lave disparue" if _replica.patches[_key].retired else "refroidissement / disparition")
	_label.text = (
		"LAVE · %s · %02d:%02d · vitesse ×%d · client/serveur : %s\n"
		+ "L : vue du cratère   K : nouvelle éruption   J : %s   Y : accélérer   M : fumée\n"
		+ "Débordement à 360° · %.0f m³ émis · %.0f m³ disparus"
	) % [
		phase, int(age) / 60, int(age) % 60, _time_rate, "IDENTIQUES" if _mismatches == 0 else "DIVERGENCE",
		"reprendre l'apport" if _source_paused else "couper l'apport", _display_injected / 1000.0, _display_removed / 1000.0]
	if not _capture_file.is_empty() and _capture_clock >= 12.0 and not _captured:
		_captured = true
		set_process(false)
		_capture()
		return
	if _accumulator >= 0.1:
		var server = _authority.patches[_key].solver
		var commands := _commands(server.tick + 1)
		_replica.physics_pending = true
		for solver in [server, _replica.patches[_key].solver]:
			var job := TickJob.new()
			job.solver = solver
			job.next_tick = _display_tick + 1
			job.commands = commands
			_jobs.append(job)
			_tasks.append(WorkerThreadPool.add_task(job.run, false, "Lava canonical tick"))
		_accumulator -= 0.1


func _join_jobs() -> void:
	for task in _tasks: WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()
	if is_instance_valid(_replica): _replica.physics_pending = false


func _compare() -> void:
	_comparisons += 1
	# Both peers live in this offline process: compare canonical bytes directly.
	# Avoid hashing megabytes twice on the render thread; captures and the
	# independent-process replay still produce full SHA-256 evidence.
	if _authority.patches[_key].solver.checkpoint() != _replica.patches[_key].solver.checkpoint():
		_mismatches += 1
		push_error("Lava client/server state divergence")


func focus_patch() -> void:
	if _key.is_empty() or not _authority.patches.has(_key):
		return
	var frame: Transform3D = _packet.frame
	var solver = _authority.patches[_key].solver
	var center_height: float = solver.terrain_q[0] / 1000.0
	var crater: float = _packet.crater_radius_m
	var target := frame * Vector3(0, center_height + 30.0, 0)
	var eye := frame * Vector3(crater * 4.5, center_height + crater * 4.0, crater * 4.5)
	var data: PlanetData = world.body.planet_data
	var up := eye.normalized()
	var ground_eye := data.radius + data.sample_height_for_direction(up) + 10.0
	if eye.length() < ground_eye:
		eye = up * ground_eye
	world._anchor = eye
	world._update_system_frame()
	var toward := (target - eye).normalized()
	var forward := (toward - up * toward.dot(up)).normalized()
	var player: Player = world.player
	player.god_mode = true
	player.transform = Transform3D(Basis(forward.cross(up).normalized(), up, -forward), eye)
	player.camera_pivot.rotation = Vector3(asin(clampf(toward.dot(up), -1.0, 1.0)), 0, 0)
	player.call_deferred("server_teleport_to", world.body, player.position)
	world.flight_speed = 100.0
	player.camera.fov = 65.0


func _start_preview() -> void:
	_remove_preview()
	_profile = VolcanoActivityProfile.for_planet(world.body.planet_data.planet_name)
	_preview = VolcanoEvent.new()
	_preview.label = "Essai local lave visqueuse"
	_preview.volcano_key = str(_packet.volcano_key)
	_preview.start_unix = VolcanoPlume.clock()
	_preview.duration_s = _duration_s
	_preview.ramp_up_s = 2.0
	_preview.ramp_down_s = 10.0
	_preview.strength = 1.0
	_profile.events.append(_preview)
	_source_paused = false
	if _authority.patches.has(_key):
		_event_start_tick = _authority.patches[_key].solver.tick


func _sync_event_visual() -> void:
	if _preview != null and _authority.patches.has(_key):
		# Plume and rocks follow the same simulated time, even in time lapse.
		_preview.start_unix = VolcanoPlume.clock() - (_authority.patches[_key].solver.tick - _event_start_tick) / 10.0


func _remove_preview() -> void:
	if _profile != null and _preview != null:
		_profile.events.erase(_preview)
	_preview = null


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or _loading or _key.is_empty():
		return
	match event.physical_keycode:
		KEY_L: focus_patch()
		KEY_K: _restart_requested = true
		KEY_J: _source_paused = not _source_paused
		KEY_Y: _time_rate = 4 if _time_rate == 1 else (12 if _time_rate == 4 else 1)
		KEY_M: _replica.set_smoke(not _replica.smoke_enabled)
		_: return
	get_viewport().set_input_as_handled()


func _capture() -> void:
	await RenderingServer.frame_post_draw
	var error := get_viewport().get_texture().get_image().save_png(_capture_file)
	_compare()
	var server = _authority.patches[_key].solver
	var client = _replica.patches[_key].solver
	var presentation: Dictionary = _replica.patches[_key]
	var wetmap := Image.create(server.width, server.height, false, Image.FORMAT_RGB8)
	for i in server.volume_q.size():
		wetmap.set_pixel(i % server.width, i / server.width,
			Color.RED if server.volume_q[i] * 1000000 > server.areas_q[i] * 3 else Color.BLACK)
	wetmap.resize(server.width * 4, server.height * 4, Image.INTERPOLATE_NEAREST)
	wetmap.save_png(_capture_file.get_basename() + "-field.png")
	FileAccess.open(_capture_file.get_basename() + "-state.bin", FileAccess.WRITE).store_buffer(server.checkpoint())
	var timings := _times.duplicate()
	timings.sort()
	var boundary_q := 0
	for i: int in server.wet_indices:
		if i >= server.width * (server.height - 1):
			boundary_q += server.volume_q[i]
	var physics := _physics_times.duplicate()
	physics.sort()
	var report := {"physics_pair_cpu_ms_p95": physics[mini(physics.size() - 1, int(physics.size() * 0.95))] if not physics.is_empty() else 0.0,
		"planet": _packet.planet, "volcano": _packet.volcano_key, "tick": server.tick,
		"gravity_milli": server.gravity_milli, "server_sha256": server.state_digest(), "client_sha256": client.state_digest(),
		"comparisons": _comparisons, "mismatches": _mismatches, "grid": [server.width, server.height],
		"cell_mm": server.cell_mm, "terrain_build_ms": _packet.build_ms,
		"simulated_seconds": server.tick / 10.0, "eruption_seconds": _duration_s,
		"injected_m3": server.injected_q / 1000.0, "wet_cells": server.wet_indices.size(),
		"authored_lava_enabled": LavaSettings.authored_flows_enabled,
		"source_radius_from_summit_m": _packet.source_radius_from_summit_m,
		"native_backend": server.has_native_backend() and client.has_native_backend(),
		"active_cells": server.active_indices.size(), "updated_cells": server.last_updated_cells,
		"geometry": "polar", "field_radius_m": _packet.field_radius_m,
		"removed_m3": server.removed_q / 1000.0, "retired": presentation.retired,
		"visual_nodes": _replica.get_child_count(),
		"boundary_volume_q": boundary_q,
		"terrain_lava_overlays": _replica._overlay_targets.size(),
		"overlay_matrix": str(presentation.overlay.get_shader_parameter("patch_from_view")) if presentation.overlay != null else "retired",
		"camera_in_patch": str((_packet.frame as Transform3D).affine_inverse() * world.player.position),
		"runtime_processing": _replica.is_processing() and _replica.can_process(),
		"main_visual_publish_ms_p95": timings[mini(timings.size() - 1, int(timings.size() * 0.95))] if not timings.is_empty() else 0.0,
		"fps": Engine.get_frames_per_second(), "capture_error": error,
		"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(view._vp)}
	FileAccess.open(_capture_file.get_basename() + ".json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("LAVA_GAME_CAPTURE ", JSON.stringify(report))
	await world.shutdown()
	get_tree().quit(0 if _mismatches == 0 and error == OK and (int(report.terrain_lava_overlays) > 0 or server.cleanup_complete()) else 1)


func _exit_tree() -> void:
	_join_jobs()
	_remove_preview()
