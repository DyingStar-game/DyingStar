extends Node3D
## Offline test world. Loads shipped planet scenes and their manifests without terrain overrides,
## manual volcanoes, cave collections or authoring UI. VFX are spawned by PlanetTerrain itself.

const PLAYER_SCENE := preload("res://scenes/player/player.tscn")
const BODY_KEY := "tarsis_3"

var player: Player
var body: Planet
var collision_terrain: PlanetTerrain
var flight_speed := 200.0
var _universe: Node3D
var _system_bodies: Dictionary = {}
var _parent_keys: Dictionary = {}
var _anchor := Vector3.ZERO
var _busy := true
var _closing := false
var _tick := 0.0
var _held: Dictionary = {}
var _saved_universe: Node
var _saved_time_offset := 0.0
var _saved_auto_quit := true
var _saved_plume_time := 0.0


func _ready() -> void:
	process_physics_priority = -10
	_saved_universe = NetworkOrchestrator.universe_scene
	_saved_time_offset = Globals.debug_time_offset
	_saved_plume_time = VolcanoPlume.debug_time_shift
	_saved_auto_quit = get_tree().auto_accept_quit
	get_tree().auto_accept_quit = false
	get_window().title = "DyingStar — Volcans de Tarsis III"
	get_window().close_requested.connect(_close_tool)
	get_window().focus_exited.connect(_release_controls)
	_build_system()
	body = _system_bodies[BODY_KEY]
	_update_system_frame()
	collision_terrain = PlanetTerrain.new()
	collision_terrain.name = "VolcanoCollisionTerrain"
	body.add_child(collision_terrain)
	collision_terrain.initialize(body.planet_data.duplicate(true), true)
	player = PLAYER_SCENE.instantiate()
	player.offline_local_authority = true
	player.client_uuid = "volcano-local-viewer"
	player.get_node("UserInterface").process_mode = Node.PROCESS_MODE_DISABLED
	player.get_node("UserInterface").hide()
	player.spawn_position = Vector3.UP * (body.planet_data.radius + 1000.0)
	player.god_mode = true
	body.add_child(player)
	player.camera.current = true
	player.camera.near = 0.05
	player.camera.far = 1.0e13
	player.camera.fov = 85.0
	player.puppet.hide()
	player.astronaut.hide()
	player.client_action_requested.connect(player.server_action_received)
	ClientSky.attach(player)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_busy = false


func _build_system() -> void:
	_universe = Node3D.new()
	_universe.name = "TarsisSystem"
	add_child(_universe)
	NetworkOrchestrator.universe_scene = _universe
	_universe.add_child(load("res://scenes/_universe/environment/space/star.tscn").instantiate())
	for filename in SystemScenes.body_files("tarsis"):
		var key := filename.get_basename()
		var planet: Planet = load(SystemScenes.body_path("tarsis", key)).instantiate()
		planet.name = key
		# Network props are owned by a regular game session, not this local test.
		for child in planet.get_children():
			if child.name != "PlanetTerrain":
				child.free()
		planet.planet_data = planet.planet_data.duplicate(true)
		planet.planet_data.apply_chunk_manifest()
		var parent_key := SystemScenes.parent_key_of(key, _system_bodies)
		_parent_keys[key] = parent_key
		var parent: Node3D = _system_bodies[parent_key] if not parent_key.is_empty() else _universe
		parent.add_child(planet)
		planet.set_physics_process(false)
		_system_bodies[key] = planet


func _update_system_frame() -> void:
	if not is_instance_valid(body):
		return
	var poses: Dictionary = {}
	var time := Globals.sim_time()
	for key: String in _system_bodies:
		var planet: Planet = _system_bodies[key]
		var parent_key: String = _parent_keys[key]
		var center := planet.orbit_offset_at(time)
		if not parent_key.is_empty():
			center += (poses[parent_key] as Transform3D).origin
		poses[key] = Transform3D(planet.spin_basis_at(time), center)
	var reference: Transform3D = poses[BODY_KEY]
	var frame := Transform3D(Basis.IDENTITY, -_anchor) * reference.affine_inverse()
	for key: String in _system_bodies:
		(_system_bodies[key] as Planet).global_transform = frame * (poses[key] as Transform3D)
	body.global_transform = Transform3D(Basis.IDENTITY, -_anchor)
	_universe.get_node("Star").global_transform = frame


func _physics_process(delta: float) -> void:
	if _busy or _closing or not is_instance_valid(player):
		return
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and get_window().has_focus()
	var movement := Vector2.ZERO
	if captured:
		movement = (
			Vector2(
				float(_pressed("move_right")) - float(_pressed("move_left")), float(_pressed("move_back")) - float(_pressed("move_forward"))
			)
			. limit_length(1.0)
		)
	player.up_direction = body.global_position.direction_to(player.global_position)
	if not player.god_mode:
		player.orient_player()
	player.input_direction = movement
	player.input_from_server = {"input_direction": movement, "rotation": player.rotation, "frame": PropSpawn.parent_frame_uuid(player)}
	player.new_input_from_server = true
	var sprint := captured and _pressed("sprint")
	player.server_action_received({"action": "sprint", "held": sprint})
	var vertical := float(_held.has(KEY_SPACE)) - float(_held.has(KEY_CTRL)) if captured else 0.0
	player.server_action_received({"action": "thrust_vertical", "value": vertical})
	player.god_mode_speed = GodMode.clamp_speed(flight_speed * (5.0 if sprint else 1.0))
	_tick += delta
	if _tick >= 0.4:
		_tick = 0.0
		_update_system_frame()
		_update_collision_residency()


func _update_collision_residency() -> void:
	var key := (
		collision_terrain.collision_chunk_key(player.global_position) if body.surface_altitude_of(player.global_position) < 3000.0 else ""
	)
	var desired := PackedStringArray()
	if not key.is_empty():
		desired.append(key)
		var ipix := PlanetTerrain._parse_ipix_from_key(key)
		var nside := PlanetTerrain._parse_nside_from_key(key)
		for neighbor in HEALPix.get_neighbors_nest(nside, ipix).values():
			if int(neighbor) >= 0:
				desired.append("hp_n%d_p%d" % [nside, int(neighbor)])
	collision_terrain.set_resident_chunks(desired)


func _pressed(action: String) -> bool:
	for event: InputEventKey in _held.values():
		if event.is_action(action):
			return true
	return false


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if not event.pressed:
			_held.erase(key)
		elif not event.echo and get_window().has_focus() and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_held[key] = event.duplicate()


func _unhandled_input(event: InputEvent) -> void:
	if _busy or _closing:
		return
	if event is InputEventKey and event.pressed:
		var step := 0.0
		if InputCombo.pressed(event, "debug_time_forward", true):
			step = Globals.DEBUG_TIME_STEP
		elif InputCombo.pressed(event, "debug_time_back", true):
			step = -Globals.DEBUG_TIME_STEP
		if step != 0.0:
			Globals.debug_time_offset += step
			_update_system_frame()
			get_viewport().set_input_as_handled()
			return
		if event.physical_keycode == KEY_ESCAPE:
			_release_controls()
		elif event.physical_keycode == KEY_SPACE and not player.god_mode and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			player.server_action_received({"action": "jump"})
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		player.rotate_object_local(Vector3.UP, -event.relative.x * 0.002)
		player.camera_pivot.rotation.x = clampf(player.camera_pivot.rotation.x - event.relative.y * 0.002, -1.5, 1.5)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			capture_controls()
		elif player.god_mode and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				flight_speed = GodMode.next_speed(flight_speed, 1)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				flight_speed = GodMode.next_speed(flight_speed, -1)


## Camera keys must never also activate the previously focused settings/preview button.
func capture_controls() -> void:
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null:
		focused.release_focus()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _release_controls() -> void:
	_held.clear()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if not is_instance_valid(player):
		return
	player.input_direction = Vector2.ZERO
	player.input_from_server = {"input_direction": Vector2.ZERO, "rotation": player.rotation, "frame": PropSpawn.parent_frame_uuid(player)}
	player.new_input_from_server = true
	player.server_action_received({"action": "sprint", "held": false})
	player.server_action_received({"action": "thrust_vertical", "value": 0.0})
	if player.god_mode:
		player.velocity = Vector3.ZERO


func _close_tool() -> void:
	if _closing:
		return
	await shutdown()
	get_tree().quit()


func shutdown() -> void:
	_closing = true
	_release_controls()
	set_physics_process(false)
	player.process_mode = Node.PROCESS_MODE_DISABLED
	var terrains: Array[PlanetTerrain] = [collision_terrain]
	for planet: Planet in _system_bodies.values():
		terrains.append(planet.planet_terrain)
	for terrain in terrains:
		terrain.set_process(false)
		terrain.set_physics_process(false)
		if terrain.stargrot_registry != null:
			terrain.stargrot_registry.retire()
	for terrain in terrains:
		await terrain.quiesce_offline()
		terrain.planet_data.clear_grade_profiles()
	await get_tree().process_frame
	RenderingServer.force_sync()


func _exit_tree() -> void:
	NetworkOrchestrator.universe_scene = _saved_universe if is_instance_valid(_saved_universe) else null
	Globals.debug_time_offset = _saved_time_offset
	VolcanoPlume.debug_time_shift = _saved_plume_time
	get_tree().auto_accept_quit = _saved_auto_quit
