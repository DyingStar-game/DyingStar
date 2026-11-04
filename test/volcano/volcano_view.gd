extends Node
## Standalone visit of the existing Tarsis III volcanoes, using the game's terrain, sky and player.
## Run: godot --path . res://test/volcano/volcano_view.tscn -- --volcano-view [--capture]
const FLANK_M := 2300.0

var explorer: Node
var active: Array[VolcanoRelief.Volcano] = []
var current := 0
var _hud: Label
var _flash: ColorRect
var _hits_seen := 0
var _shake := 0.0
var _vp: RID
var _capturing := false
var _gpu_samples: Array[float] = []
var _walking_pending := false
var _control_panel: PanelContainer


func _ready() -> void:
	explorer = preload("res://test/volcano/volcano_world.gd").new()
	add_child(explorer)
	while explorer.player == null or explorer._busy:
		await get_tree().process_frame
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	_build_hud()
	var layer := CanvasLayer.new()
	layer.layer = 60
	add_child(layer)
	_control_panel = preload("res://test/volcano/volcano_control_panel.gd").new()
	_control_panel.world = explorer
	layer.add_child(_control_panel)
	_control_panel.hide()
	var seen := {}
	var data: PlanetData = explorer.body.planet_data
	for ip in 12:
		for vv in data.get_chunk_volcanoes(1, ip):
			var v: VolcanoRelief.Volcano = vv
			var key := VolcanoFeatures.key_of(v)
			if not seen.has(key) and v.activity == "active" and v.type == "stratovolcano":
				seen[key] = true
				active.append(v)
	print("[VOLCANO] %d stratovolcans actifs" % active.size())
	if active.is_empty():
		_hud.text = "Aucun volcan actif sur cette planete."
		return
	_go_to(0)
	await _settle(1.0)
	await _shift_sun(0.55, true)
	_go_to(0)
	if "--smoke-test" in OS.get_cmdline_user_args():
		await _smoke_test()
		return
	if "--capture" in OS.get_cmdline_user_args():
		await _capture()
		await explorer.shutdown()
		get_tree().quit()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	_flash = ColorRect.new()
	_flash.color = Color(0.8, 0.05, 0.0, 0.0)
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_flash)
	_hud = Label.new()
	_hud.position = Vector2(14, 200)
	_hud.add_theme_font_size_override("font_size", 15)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 4)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_hud)
	add_child(layer)


## Rebase the offline world on the flank of volcano [param index], in free flight, looking at its summit.
func _go_to(index: int, flank_m: float = FLANK_M, above_m: float = 3.0, back_lit: bool = false) -> void:
	current = posmod(index, active.size())
	var v: VolcanoRelief.Volcano = active[current]
	var data: PlanetData = explorer.body.planet_data
	var up := v.c.normalized()
	var ref := Vector3.UP if absf(up.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var east := up.cross(ref).normalized()
	# On the sun's side of the volcano by default, the light behind the viewer.
	var star: Node3D = explorer._universe.get_node("Star")
	var to_star: Vector3 = explorer.body.global_position.direction_to(star.global_position)
	var along := to_star - up * to_star.dot(up)
	if along.length() > 0.01:
		east = along.normalized() * (-1.0 if back_lit else 1.0)
	var dir := (v.c + east * (flank_m / data.radius)).normalized()
	if above_m < 10.0:
		dir = _open_spot(v, east, flank_m)
	var at := dir * (data.radius + data.sample_height_for_direction(dir) + above_m)
	explorer._anchor = at
	explorer._update_system_frame()
	var player: Player = explorer.player
	player.god_mode = true
	var local_up := dir
	var summit := v.c.normalized() * (data.radius + data.sample_height_for_direction(v.c))
	var forward := summit - at
	forward = (forward - local_up * forward.dot(local_up)).normalized()
	player.transform = Transform3D(Basis(forward.cross(local_up).normalized(), local_up, -forward), at)
	player.camera_pivot.rotation = Vector3(0.28, 0.0, 0.0)
	player.call_deferred("server_teleport_to", explorer.body, player.position)
	explorer.flight_speed = 200.0


## The gentlest ground on a ring around the summit, near the sun's side: a player set down in a gully sees
## two walls and no sky. Each try reads the planet's heights, so this is only for a move, never per frame.
func _open_spot(v: VolcanoRelief.Volcano, toward: Vector3, flank_m: float) -> Vector3:
	var data: PlanetData = explorer.body.planet_data
	var up := v.c.normalized()
	var side := up.cross(toward).normalized()
	var best := (v.c + toward * (flank_m / data.radius)).normalized()
	var best_score := INF
	for k in 32:
		var a := PI * (float(k) / 16.0 - 1.0) * 0.6
		var ring := flank_m * (1.0 + 0.5 * float(k % 3))
		var tangent := toward * cos(a) + side * sin(a)
		var dir := (v.c + tangent * (ring / data.radius)).normalized()
		var h := data.sample_height_for_direction(dir)
		var rough := 0.0
		for d: Vector3 in [tangent, -tangent, side.rotated(up, a), -side.rotated(up, a)]:
			for reach: float in [12.0, 45.0]:
				rough += absf(data.sample_height_for_direction((dir + d * (reach / data.radius)).normalized()) - h) / reach
		if rough < best_score:
			best_score = rough
			best = dir
	print("[VOLCANO] endroit degage : pente moyenne %.0f %%" % (best_score / 8.0 * 100.0))
	return best


## The next moment the volcano really works, plus a little for the column to build up.
func _jump_to_burst() -> void:
	await get_tree().process_frame
	var plume := VolcanoPlume.nearest()
	if plume == null:
		return
	var base := VolcanoPlume.clock()
	var shift := 0.0
	var found := false
	for k in 400:
		if plume.model.activity(base + shift) > 1.0:
			found = true
			break
		shift += 10.0
	if found:
		VolcanoPlume.debug_time_shift += shift + 20.0


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F2:
		_control_panel.visible = not _control_panel.visible
		if _control_panel.visible:
			explorer._release_controls()
		get_viewport().set_input_as_handled()
		return
	if not event is InputEventKey or not event.pressed or event.echo or active.is_empty():
		return
	match event.physical_keycode:
		KEY_N:
			_jump_to_burst()
		KEY_V:
			_go_to(current + 1)
			_jump_to_burst()
		KEY_B:
			_volley(40, 35.0)
		KEY_H:
			_hud.visible = not _hud.visible
		KEY_T:
			_toggle_walk()
		_:
			return
	get_viewport().set_input_as_handled()


## Stay in flight until the real server terrain has collision under the player.
func _toggle_walk() -> void:
	if _walking_pending:
		return
	var player: Player = explorer.player
	if player.god_mode:
		_walking_pending = true
		explorer._update_collision_residency()
		var waited := 0.0
		while waited < 12.0 and not explorer.collision_terrain.has_collision_under(player.global_position):
			waited += 0.2
			await get_tree().create_timer(0.2).timeout
		_walking_pending = false
		if not explorer.collision_terrain.has_collision_under(player.global_position):
			print("[VOLCANO] collision encore en chargement, vol conserve")
			return
	player.god_mode = not player.god_mode
	player.server_teleport_to(explorer.body, player.position)
	if not player.god_mode:
		player._role._ground_seen = true


## Exercise the actual terrain registry and rendered VFX, not a manually attached plume.
func _smoke_test() -> void:
	var key := VolcanoFeatures.key_of(active[current])
	var deadline := Time.get_ticks_msec() + 90000
	var plume: VolcanoPlume = null
	while Time.get_ticks_msec() < deadline:
		var entry: Dictionary = explorer.body.planet_terrain._volcano_nodes.get(key, {})
		if not entry.is_empty():
			plume = entry.node.get_node_or_null("Plume") as VolcanoPlume
			if plume != null and plume.stones != null and plume._frame_no > 4:
				break
		await get_tree().process_frame
	var ok := plume != null and plume.stones != null and plume._frame_no > 4
	print(
		(
			"VOLCANO WORLD: %s, Tarsis III volcano %s, terrain registry %d, plume rendered %s"
			% ["PASS" if ok else "FAIL", key, explorer.body.planet_terrain._volcano_nodes.size(), ok]
		)
	)
	if ok:
		await _settle(3.0)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://volcano_smoke_test.png")
		_control_panel.show()
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://volcano_control_panel.png")
		_control_panel.hide()
		var live := VolcanoActivityProfile.for_planet(explorer.body.planet_data.planet_name)
		var saved_events := live.events.duplicate()
		_control_panel._add_event()
		_control_panel._commit(false)
		ok = live.events.size() == saved_events.size() + 1
		_control_panel._draft.events.clear()
		ok = ok and live.events.size() == saved_events.size() + 1
		_control_panel._draft.events.assign(saved_events)
		_control_panel._commit(false)
		print("VOLCANO PANEL APPLY: %s (event creation, live apply, draft isolation, terrain rebuild)" % ("PASS" if ok else "FAIL"))
		for mode in 3:
			_control_panel._preview(mode)
			ok = ok and not live.random_enabled and live.idle_strength == 0.0
			ok = ok and live.events.size() == (0 if mode == 0 else 1)
			if mode != 0:
				ok = ok and live.events[0].eruption_enabled == (mode == 2)
			await get_tree().process_frame
		_control_panel._commit(false)
		print("VOLCANO PANEL STATES: %s (off, smoke-only, eruption previews and draft restoration)" % ("PASS" if ok else "FAIL"))
		ok = await _test_preview_camera_input() and ok
		_control_panel._commit(false)
	await explorer.shutdown()
	get_tree().quit(0 if ok else 1)


func _test_preview_camera_input() -> bool:
	_control_panel.show()
	var button: Button
	for child in _control_panel._box.get_children():
		if child is Button and child.text == "Apercu : formation d'un panache seul":
			button = child
	if button == null:
		return false
	button.grab_focus()
	button.pressed.emit()
	await get_tree().process_frame
	var live := VolcanoActivityProfile.for_planet(explorer.body.planet_data.planet_name)
	var start: float = live.events[0].start_unix
	# Re-enter the camera, then use Space to fly up. GUI focus must not restart the preview.
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	explorer._unhandled_input(click)
	var turn := InputEventMouseMotion.new()
	turn.relative = Vector2(20, -10)
	explorer._unhandled_input(turn)
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.physical_keycode = KEY_SPACE
	space.pressed = true
	Input.parse_input_event(space)
	await get_tree().process_frame
	space = space.duplicate()
	space.pressed = false
	Input.parse_input_event(space)
	await get_tree().process_frame
	var ok := live.events.size() == 1 and live.events[0].start_unix == start
	ok = ok and get_viewport().gui_get_focus_owner() == null
	ok = ok and not _control_panel.visible
	print("VOLCANO PREVIEW CAMERA: %s (mouse capture, rotation and flight key preserve event start)" % ("PASS" if ok else "FAIL"))
	explorer._release_controls()
	_control_panel.hide()
	return ok


## The star's height over the player's horizon, -1..1, from the real positions.
func _sun_height() -> float:
	var player: Player = explorer.player
	var up: Vector3 = explorer.body.global_position.direction_to(player.global_position)
	var star: Node3D = explorer._universe.get_node("Star")
	return up.dot(player.global_position.direction_to(star.global_position))


func _shift_sun(wanted: float, above: bool) -> void:
	var day: float = explorer.body.rotation_period_hours if explorer.body.rotation_period_hours > 0.0 else 24.0
	for _k in 96:
		var h := _sun_height()
		if (above and h >= wanted) or (not above and h <= wanted):
			break
		Globals.debug_time_offset += day * 3600.0 / 96.0
		explorer._update_system_frame()
		await get_tree().process_frame
	print("[VOLCANO] soleil a %.0f deg" % rad_to_deg(asin(clampf(_sun_height(), -1.0, 1.0))))


func _volley(n: int, spread_m: float) -> void:
	var plume := VolcanoPlume.nearest()
	if plume == null or plume.stones == null:
		return
	var eye := plume.to_local(explorer.player.camera.global_position)
	plume.stones.volley_at(eye + Vector3.DOWN * 1.7, n, VolcanoPlume.clock(), spread_m)


func _process(delta: float) -> void:
	if _hud == null:
		return
	if VolcanoPlume.hits_total > _hits_seen:
		_hits_seen = VolcanoPlume.hits_total
		_flash.color.a = 0.45
		_shake = 1.0
	_flash.color.a = maxf(_flash.color.a - delta * 1.1, 0.0)
	if _shake > 0.0 and is_instance_valid(explorer.player):
		_shake = maxf(_shake - delta * 1.6, 0.0)
		explorer.player.camera.h_offset = (randf() - 0.5) * _shake * 0.3
		explorer.player.camera.v_offset = (randf() - 0.5) * _shake * 0.3
	var plume := VolcanoPlume.nearest()
	if plume == null:
		_hud.text = "Le terrain charge..."
		return
	var now := plume.model.activity(VolcanoPlume.clock())
	_hud.text = (
		(
			(
				"Volcan %d/%d   |   %s   |   activite %.2f   |   %d fps, GPU %.1f ms   |   a %.1f km   |   "
				+ "pierres : %d en vol, %d roches   |   touches : %d   |   %s\n"
			)
			% [
				current + 1,
				active.size(),
				plume.model.state_label(VolcanoPlume.clock()),
				now,
				Engine.get_frames_per_second(),
				RenderingServer.viewport_get_measured_render_time_gpu(_vp),
				plume._dist / 1000.0,
				plume.stones.in_flight(VolcanoPlume.clock()),
				plume.stones.props_alive(),
				VolcanoPlume.hits_total,
				"en vol" if explorer.player.god_mode else "A PIED"
			]
		)
		+ "Clic : prendre la souris   ZQSD : bouger   Espace/Ctrl : monter/descendre en vol   "
		+ "Molette : vitesse de vol   Maj : vite   T : marcher / voler\n"
		+ "F2 : reglages et evenements   B : salve sur moi   N : prochaine forte activite   V : volcan suivant   "
		+ "+/- : heure du jour   Echap : liberer la souris   H : masquer"
	)


func _settle(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(file: String) -> void:
	await RenderingServer.frame_post_draw
	var plume := VolcanoPlume.nearest()
	var line := (
		"%s : %d fps, GPU %.1f ms" % [file, Engine.get_frames_per_second(), RenderingServer.viewport_get_measured_render_time_gpu(_vp)]
	)
	if plume != null:
		line += (
			", %.1f km, %d en vol, %d roches, activite %.2f"
			% [
				plume._dist / 1000.0,
				plume.stones.in_flight(VolcanoPlume.clock()),
				plume.stones.props_alive(),
				plume.model.activity(VolcanoPlume.clock())
			]
		)
	print("[VOLCANO] ", line)
	get_viewport().get_texture().get_image().save_png("user://volcano_%s.png" % file)


## What the R&D needs on a real planet: from afar, from the flank, on foot under the stones. Daylight.
func _capture() -> void:
	_capturing = true
	var player: Player = explorer.player
	await _settle(2.0)
	await _shift_sun(0.55, true)
	await _settle(25.0)
	await _shot("flanc_vol")
	_go_to(current, 14000.0, 900.0)
	explorer.player.camera_pivot.rotation = Vector3(0.14, 0.0, 0.0)
	await _settle(25.0)
	await _shot("14km")
	_go_to(current, 14000.0, 900.0, true)
	explorer.player.camera_pivot.rotation = Vector3(0.14, 0.0, 0.0)
	await _settle(15.0)
	await _shot("contrejour")
	_go_to(current, 40000.0, 3500.0)
	explorer.player.camera_pivot.rotation = Vector3(0.0, 0.0, 0.0)
	await _settle(25.0)
	await _shot("40km")
	_go_to(current, FLANK_M, 3.0)
	await _settle(20.0)
	await _jump_to_burst()
	await _toggle_walk()
	await _settle(6.0)
	var data: PlanetData = explorer.body.planet_data
	var dir: Vector3 = explorer.body.to_local(player.global_position).normalized()
	player.camera_pivot.rotation = Vector3(0.55, 0.0, 0.0)
	print(
		(
			"[VOLCANO] a pied : god %s, sur le sol %s, altitude au-dessus du relief %.2f m"
			% [
				player.god_mode,
				player.is_on_floor(),
				explorer.body.to_local(player.global_position).length() - data.radius - data.sample_height_for_direction(dir)
			]
		)
	)
	await _shot("pied")
	_volley(40, 40.0)
	await _settle(9.0)
	await _shot("salve")
	await _settle(5.0)
	await _shot("salve_apres")
	await _rock_shot()
	_volley(3, 0.0)
	await _settle(12.0)
	print("[VOLCANO] touches : %d, plume sample : terrain ok" % VolcanoPlume.hits_total)
	var plume := VolcanoPlume.nearest()
	var t0 := Time.get_ticks_usec()
	var n := 0
	var eye := plume.to_local(player.camera.global_position)
	for k in 2000:
		plume._relief(eye.x + float(k), eye.z)
		n += 1
	print("[VOLCANO] _relief : %.1f us par echantillon" % (float(Time.get_ticks_usec() - t0) / float(n)))
	await _toggle_walk()
	_go_to(current, 9000.0, 300.0)
	explorer.player.camera_pivot.rotation = Vector3(0.2, 0.0, 0.0)
	await _shift_sun(-0.35, false)
	await _settle(15.0)
	await _shot("nuit")
	_capturing = false


## A close look at the biggest rock lying near the player.
func _rock_shot() -> void:
	var plume := VolcanoPlume.nearest()
	var player: Player = explorer.player
	var best: VolcanoStoneField.Rock = null
	for rock: VolcanoStoneField.Rock in plume.stones._rocks:
		if rock.asleep and (best == null or rock.r > best.r):
			best = rock
	if best == null:
		return
	print("[VOLCANO] plus grosse roche : %.2f m" % best.r)
	player.god_mode = true
	var at: Vector3 = plume.to_global(best.p)
	var up: Vector3 = explorer.body.global_position.direction_to(at)
	var side := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	var eye := at + side * best.r * 3.4 + up * best.r * 0.9
	var forward := at - eye
	forward = (forward - up * forward.dot(up)).normalized()
	player.global_transform = Transform3D(Basis(forward.cross(up).normalized(), up, -forward), eye)
	player.camera_pivot.rotation = Vector3(-0.22, 0.0, 0.0)
	await _settle(1.0)
	await _shot("roche")
	player.camera_pivot.rotation = Vector3(0.55, 0.0, 0.0)
	await _toggle_walk()
