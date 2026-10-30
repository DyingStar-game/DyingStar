extends Node3D
## Offline authoring scene, using real body scenes, PlanetTerrain and PlayerServer.
## Network deployment is a separate validation; this scene starts no game service.

const PLAYER_SCENE := preload("res://scenes/player/player.tscn")
const PLACEMENT_PATH := "user://stargrot_manual_cave.tres"
const COLLECTION_PATH := "user://stargrot_sites.tres"
const DEFAULT_PLACEMENT := "res://levels/stargrot/initial_cave.tres"
const SPEEDS := [3.0, 15.0, 200.0, 2000.0, 25000.0, 1000000.0]

## Tests inject a separate path before adding this scene to the tree.
var placement_path: String = PLACEMENT_PATH
var collection_path: String = COLLECTION_PATH
var collection: CaveSiteCollection
var _undo_collection: CaveSiteCollection
var _delete_all_button: Button
var _load_error: String = ""
var player: Player
var body: Planet
var collision_terrain: PlanetTerrain
var placement: CavePlacement
var _draft_profile: CaveProfile
var _draft_seed: int
var _draft_label: Label
var _workbench: CaveWorkbench
var _export_dialog: FileDialog
var bodies := PackedStringArray()
var selected_key: String = "tarsis_3"
var flight_speed: float = 3.0
var _menu: Window
var _site_list: ItemList
var _site_name: LineEdit
var _delete_button: Button
var _undo_button: Button
var _add_button: Button
var _copy_button: Button
var _status: Label
var _hint: Label
var _planets: OptionButton
var _longitude: SpinBox
var _latitude: SpinBox
var _heading: SpinBox
var _busy: bool = false
var _collision_tick: float = 0.0
var _placement_button: Button
var _speeds: OptionButton
var _inspection_light: OmniLight3D
var _universe: Node3D
var _system_bodies: Dictionary = {}
var _parent_keys: Dictionary = {}
var _anchor := Vector3.ZERO
var _sun: PlayerSunLight
var _markers: CelestialGizmos
var _saved_universe: Node
var _saved_time_offset: float
var _system_tick: float = 0.0
var _saved_embed: bool
var _population: CavePopulation
var _batch_count: SpinBox
var _batch_seed: SpinBox
var _batch_button: Button
var _batch_cancel: Button
var _batch_status: Label
var _batch_replace: CheckButton
var _undo_body: String = ""
var _export_catalog: bool = false
var _picker: CaveSurfacePicker
var _place_hint: Label
var _keep_view: bool = false
var _closing: bool = false
var _saved_auto_quit: bool
var _placement_light: DirectionalLight3D
var _placement_pins := PackedStringArray()
var _navigation := CaveExplorerInput.new()


func _ready() -> void:
    process_physics_priority = -10
    _saved_universe = NetworkOrchestrator.universe_scene
    _saved_time_offset = Globals.debug_time_offset
    _saved_auto_quit = get_tree().auto_accept_quit
    get_tree().auto_accept_quit = false
    get_window().close_requested.connect(_close_tool)
    get_window().focus_exited.connect(_release_controls)
    _saved_embed = get_viewport().gui_embed_subwindows
    get_viewport().gui_embed_subwindows = false
    get_window().title = "StarGrotte 0.9 • Vue planétaire"
    get_window().mode = Window.MODE_WINDOWED
    if placement_path != PLACEMENT_PATH and collection_path == COLLECTION_PATH:
        collection_path = placement_path.get_basename() + "_sites.tres"
    bodies = SystemScenes.body_files("tarsis")
    _make_ui()
    _load_collection()
    placement = collection.selected()
    var draft: CavePlacement = placement if placement else load(DEFAULT_PLACEMENT)
    _select_definition(draft.profile, draft.seed)
    _build_system()
    _load_body(placement.planet_name if placement else "tarsis_3")
    _sync_sites()
    if not _load_error.is_empty():
        _hint.text = _load_error
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    if "--stargrot-workbench" in OS.get_cmdline_user_args():
        _open_workbench.call_deferred()


func _exit_tree() -> void:
    NetworkOrchestrator.universe_scene = _saved_universe if is_instance_valid(_saved_universe) else null
    Globals.debug_time_offset = _saved_time_offset
    get_viewport().gui_embed_subwindows = _saved_embed
    get_tree().auto_accept_quit = _saved_auto_quit


func _close_tool() -> void:
    if _closing:
        return
    await shutdown()
    get_tree().quit()


## Finish authoring and native jobs while their nodes and the main loop still exist.
func shutdown() -> void:
    _closing = true
    _workbench.hide()
    get_viewport().disable_3d = true
    _population.cancelled = true
    _picker.stop()
    _place_hint.show()
    _place_hint.text = "Fermeture de l’atelier…"
    while _busy:
        await get_tree().process_frame
    set_physics_process(false)
    player.process_mode = Node.PROCESS_MODE_DISABLED
    var terrains: Array[PlanetTerrain] = [collision_terrain]
    for planet: Planet in _system_bodies.values():
        terrains.append(planet.planet_terrain)
    for terrain in terrains:
        terrain.set_process(false)
        terrain.set_physics_process(false)
        # A registry owns its own process callback and worker queue: stopping Terrain alone
        # does not stop it. Join it before the final render sync, while its data is still alive.
        if terrain.stargrot_registry != null:
            terrain.stargrot_registry.retire()
    for terrain in terrains:
        await terrain.quiesce_stargrot()
    # PlanetData owns profiling tasks outside Terrain's queue. All terrain readers
    # are stopped before reclaiming those jobs through its native cleanup method.
    for terrain in terrains:
        terrain.planet_data.clear_grade_profiles()
    await _workbench.shutdown()
    # Stop drawing before viewport/mesh owners leave the tree. Flush deferred
    # rendering work while all native resources are still alive.
    await get_tree().process_frame
    RenderingServer.force_sync()


func _load_collection() -> void:
    if ResourceLoader.exists(collection_path):
        collection = ResourceLoader.load(collection_path, "", ResourceLoader.CACHE_MODE_IGNORE) as CaveSiteCollection
        _load_error = "La collection est illisible ; son fichier est conservé." if collection == null else collection.validation_error()
        if _load_error.is_empty():
            for site in collection.sites:
                if not bodies.has(site.planet_name + ".tscn"):
                    _load_error = "Une grotte utilise un corps absent du système Tarsis."
        if _load_error.is_empty():
            _migrate_collection_coordinates()
            return  # An intentionally empty collection stays empty.
    collection = CaveSiteCollection.new()
    var initial: CavePlacement = load(DEFAULT_PLACEMENT).duplicate(true)
    if initial.resource_name.is_empty():
        initial.resource_name = "Grotte 1"
    initial.migrate_coordinates()
    collection.put(initial)


func _backup_collection() -> Error:
    var backup := collection_path.get_basename() + ".before-refit-%d.tres" % Time.get_ticks_usec()
    return collection.save_to(backup)


func _migrate_collection_coordinates() -> void:
    if not collection.sites.any(func(site: CavePlacement): return site.format_version == 1):
        return
    var next: CaveSiteCollection = collection.duplicate(true)
    for site in next.sites:
        site.migrate_coordinates()
    if _backup_collection() == OK and next.save_to(collection_path) == OK:
        collection = next
    else:
        _load_error = "Migration non sauvegardée ; le fichier précédent est conservé."


## Outdated trials remain editable, but never cut the current terrain.
func _current_sites(key: String, data: PlanetData, staged: CaveSiteCollection = null) -> Array[CavePlacement]:
    var source := staged if staged != null else collection
    return source.on_body(key).filter(func(site: CavePlacement): return site.validation_error(data).is_empty())


func _build_system() -> void:
    _universe = Node3D.new()
    _universe.name = "TarsisSystem"
    add_child(_universe)
    NetworkOrchestrator.universe_scene = _universe
    _universe.add_child(load("res://scenes/_universe/environment/space/star.tscn").instantiate())
    for filename in bodies:
        var key := filename.get_basename()
        var planet: Planet = load(SystemScenes.body_path("tarsis", key)).instantiate()
        planet.name = key
        # Local exploration uses native celestial/terrain systems; network props
        # belong to a regular server session and are not spawned by this tool.
        for child in planet.get_children():
            if child.name != "PlanetTerrain":
                child.free()
        planet.planet_data = planet.planet_data.duplicate(true)
        planet.planet_data.cave_catalog = null
        planet.planet_data.cave_placements.clear()
        planet.planet_data.apply_chunk_manifest()
        planet.planet_data.cave_placements = _current_sites(key, planet.planet_data)
        var parent_key := SystemScenes.parent_key_of(key, _system_bodies)
        _parent_keys[key] = parent_key
        var parent: Node3D = _system_bodies[parent_key] if not parent_key.is_empty() else _universe
        parent.add_child(planet)
        # The same native ephemerides are evaluated in a frame fixed to the
        # selected body. This keeps local Jolt collision stable while the sky moves.
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
    var reference: Transform3D = poses[selected_key]
    var frame := Transform3D(Basis.IDENTITY, -_anchor) * reference.affine_inverse()
    for key: String in _system_bodies:
        var planet: Planet = _system_bodies[key]
        planet.global_transform = frame * (poses[key] as Transform3D)
    # Set the selected frame exactly, avoiding round-off at astronomical distances.
    body.global_transform = Transform3D(Basis.IDENTITY, -_anchor)
    _universe.get_node("Star").global_transform = frame


func _shift_time(hours: float) -> void:
    var day_hours := body.rotation_period_hours if body.rotation_period_hours > 0.0 else 24.0
    Globals.debug_time_offset += hours / 24.0 * day_hours * 3600.0
    _update_system_frame()


func _load_body(key: String) -> void:
    if _busy:
        return
    _busy = true
    if is_instance_valid(player):
        player.free()
    if is_instance_valid(collision_terrain):
        await collision_terrain.quiesce_stargrot()
        collision_terrain.planet_data.clear_grade_profiles()
        collision_terrain.free()
    _placement_pins.clear()
    selected_key = key
    body = _system_bodies[key]
    _anchor = placement.surface_transform().origin if placement and placement.planet_name == key else Vector3.ZERO
    _update_system_frame()
    collision_terrain = PlanetTerrain.new()
    collision_terrain.name = "StargrotServerTerrain"
    body.add_child(collision_terrain)
    var server_data: PlanetData = body.planet_data.duplicate(true)
    collision_terrain.initialize(server_data, true)
    player = PLAYER_SCENE.instantiate()
    player.stargrot_local_authority = true
    player.client_uuid = "stargrot-local-explorer"
    player.get_node("UserInterface").process_mode = Node.PROCESS_MODE_DISABLED
    player.get_node("UserInterface").hide()
    player.spawn_position = Vector3.UP * (body.planet_data.radius + 1000.0)
    body.add_child(player)
    player.camera.current = true
    player.camera.near = 0.05
    player.camera.far = 1.0e13
    player.camera.fov = 85.0
    player.flashlight.visible = true
    player.flashlight.light_energy = 3.0
    _inspection_light = OmniLight3D.new()
    _inspection_light.name = "StargrotInspectionLight"
    _inspection_light.light_energy = 6.0
    _inspection_light.omni_range = 18.0
    player.camera.add_child(_inspection_light)
    _placement_light = DirectionalLight3D.new()
    _placement_light.name = "AuthoringLight"
    _placement_light.light_energy = 1.8
    _placement_light.visible = false
    player.camera.add_child(_placement_light)
    _sun = ClientSky.attach(player)
    _markers = CelestialGizmos.new()
    _markers.player = player
    player.camera.add_child(_markers)
    _markers.visible = true
    player.puppet.hide()
    player.astronaut.hide()
    player.camera_pivot.rotation = Vector3.ZERO
    # Let the normal authority update locomotion; local input supplies intent.
    player.client_action_requested.connect(player.server_action_received)
    _longitude.value = placement.longitude_deg if placement and placement.planet_name == key else 0.0
    _latitude.value = placement.latitude_deg if placement and placement.planet_name == key else 0.0
    _heading.value = placement.heading_deg if placement and placement.planet_name == key else 0.0
    _busy = false
    _planets.select(bodies.find(key + ".tscn"))
    if placement and placement.planet_name == key:
        _return_to_entrance()
    else:
        _orbit_view()


func _physics_process(delta: float) -> void:
    if not is_instance_valid(player):
        return
    if _busy or _closing:
        _stop_motion()
        return
    _system_tick += delta
    if _system_tick >= 1.0:
        _system_tick = 0.0
        _update_system_frame()
    if _picker.active:
        _picker.update_cursor(player.camera, body, collision_terrain)
        _place_hint.text = "CLIC : PLACER   •   MOLETTE : ORIENTER   •   CLIC DROIT : ANNULER" if _picker.valid else \
            "Survolez le terrain chargé • Déplacez la vue avec ZQSD / WASD"
    var captured := (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or _picker.active) and get_window().has_focus()
    var movement := _navigation.movement(captured)
    player.up_direction = body.global_position.direction_to(player.global_position)
    if not player.god_mode:
        player.orient_player()
    player.input_direction = movement
    player.input_from_server = {"input_direction": movement, "rotation": player.rotation,
        "frame": PropSpawn.parent_frame_uuid(player)}
    player.new_input_from_server = true
    var sprint := captured and _navigation.keyboard_pressed("sprint")
    player.server_action_received({"action": "sprint", "held": sprint})
    var vertical := float(_navigation.physical_pressed(KEY_SPACE)) - float(_navigation.physical_pressed(KEY_CTRL)) if captured else 0.0
    player.server_action_received({"action": "thrust_vertical", "value": vertical})
    player.god_mode_speed = GodMode.clamp_speed(flight_speed * (5.0 if sprint else 1.0))
    _collision_tick += delta
    if _collision_tick > 0.4:
        _collision_tick = 0.0
        _update_collision_residency()
    var active_cave := CavePlanetRegistry.contains(collision_terrain.planet_data, body.to_local(player.global_position))
    var server_registry := collision_terrain.stargrot_registry
    var ready := server_registry == null or server_registry.prepared
    var altitude := body.surface_altitude_of(player.global_position)
    _status.text = "%s  •  %s  •  %.1f m/s  •  altitude %.1f m\n%s" % [
        body.display_name if not body.display_name.is_empty() else selected_key,
        "GOD MODE" if player.god_mode else "À PIED", player.god_mode_speed if player.god_mode else player.velocity.length(), altitude,
        "Dans la grotte" if active_cave else ("Terrain en cours de chargement…" if not ready else "Surface / espace")]
    if server_registry and not server_registry.error_message.is_empty():
        _status.text += "\n" + server_registry.error_message
    if server_registry:
        var stats := server_registry.residency_stats()
        _status.text += " • Grottes actives : %d / %d" % [stats.resident, stats.definitions]
    # Sun height over the local horizon: + / - shift the clock until the light suits the inspection.
    var sun := (_universe.get_node("Star") as Node3D).global_position - player.global_position
    _status.text += " • Soleil : %+.0f°" % rad_to_deg(asin(clampf(player.up_direction.dot(sun.normalized()), -1.0, 1.0)))
    if not is_zero_approx(Globals.debug_time_offset - _saved_time_offset):
        _status.text += " (%+.0f h)" % ((Globals.debug_time_offset - _saved_time_offset) / 3600.0)


## No retained intent while fitting a cave, switching windows, or releasing the mouse.
func _stop_motion() -> void:
    _navigation.reset()
    if not is_instance_valid(player):
        return
    player.input_direction = Vector2.ZERO
    player.input_from_server = {"input_direction": Vector2.ZERO, "rotation": player.rotation,
        "frame": PropSpawn.parent_frame_uuid(player)}
    player.new_input_from_server = true
    player.mouse_motion = Vector2.ZERO
    player.server_action_received({"action": "sprint", "held": false})
    player.server_action_received({"action": "thrust_vertical", "value": 0.0})
    if player.god_mode:
        player.velocity = Vector3.ZERO


func _release_controls() -> void:
    _stop_motion()


func _update_collision_residency() -> void:
    var key := collision_terrain.collision_chunk_key(player.global_position) \
        if body.surface_altitude_of(player.global_position) < 3000.0 else ""
    if not key.is_empty():
        var ipix := PlanetTerrain._parse_ipix_from_key(key)
        var nside := PlanetTerrain._parse_nside_from_key(key)
        var desired := PackedStringArray([key])
        for neighbor in HEALPix.get_neighbors_nest(nside, ipix).values():
            if int(neighbor) >= 0:
                desired.append("hp_n%d_p%d" % [nside, int(neighbor)])
        collision_terrain.set_resident_chunks(desired)
    else:
        collision_terrain.set_resident_chunks(PackedStringArray())


## Observe releases before UI controls can consume them; only the focused view accepts new presses.
func _input(event: InputEvent) -> void:
    if event is InputEventKey:
        if not event.pressed or (not _busy and not _closing and get_window().has_focus() \
                and (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or _picker.active)):
            _navigation.handle_key(event)


func _unhandled_input(event: InputEvent) -> void:
    if not is_instance_valid(player) or _busy:
        return
    # The base game's sky clock (+ / -: debug_time_forward / debug_time_back), here too, even while placing:
    # one hour per press, held to sweep the light over a cave. Restored when the atelier closes.
    if Globals.is_dev_tool_enabled("debug_time") and event is InputEventKey:
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
    if _picker.handle_input(event):
        get_viewport().set_input_as_handled()
        return
    if event is InputEventKey and event.pressed and not event.echo:
        match event.physical_keycode:
            KEY_ESCAPE:
                _release_controls()
                Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
                _workbench.show_sites()
                _workbench.grab_focus()
            KEY_G:
                _toggle_flight()
            KEY_HOME:
                _return_to_entrance()
            KEY_O:
                _orbit_view()
            KEY_L:
                player.flashlight.visible = not player.flashlight.visible
                _inspection_light.visible = player.flashlight.visible
            KEY_P:
                _markers.visible = not _markers.visible
                if not _markers.visible:
                    _markers._clear()
            KEY_SPACE:
                if not player.god_mode and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
                    player.server_action_received({"action": "jump"})
    if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        player.rotate_object_local(Vector3.UP, -event.relative.x * 0.002)
        player.camera_pivot.rotation.x = clampf(player.camera_pivot.rotation.x - event.relative.y * 0.002, -1.5, 1.5)
    if event is InputEventMouseButton and event.pressed and player.god_mode and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        if event.button_index == MOUSE_BUTTON_WHEEL_UP:
            flight_speed = GodMode.next_speed(flight_speed, 1)
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            flight_speed = GodMode.next_speed(flight_speed, -1)
        _speeds.select(-1)
        _speeds.text = "Vitesse de vol : %s m/s" % str(flight_speed)
    elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
        _capture_view()


func _toggle_flight() -> void:
    if _busy:
        return
    if player.god_mode:
        # An orbiting camera cannot turn walking on in empty space. Return to the
        # entrance safely; inside the real traversable corridor switch in place.
        if not CavePlanetRegistry.contains(collision_terrain.planet_data, body.to_local(player.global_position)):
            if placement == null or placement.planet_name != selected_key:
                _hint.text = "Placez une grotte sur cette planète avant d’activer le parcours à pied."
                return
            _return_to_entrance()
            return
    player.god_mode = not player.god_mode
    player.call_deferred("server_teleport_to", body, player.position)


func _return_to_entrance() -> void:
    if _busy:
        return
    if placement == null or placement.planet_name != selected_key:
        _hint.text = "Cette planète n’a pas encore de grotte. Choisissez des coordonnées et placez-en une."
        return
    _clear_placement_pins()
    _picker.stop()
    _placement_light.hide()
    _place_hint.hide()
    var frame := placement.surface_transform()
    flight_speed = 3.0
    _speeds.select(0)
    # Rebase this offline world near the entrance, keeping Jolt near the origin.
    _anchor = frame.origin
    _update_system_frame()
    # Stay in free flight until the native chunk/cave collider has arrived.
    player.god_mode = true
    # In front of a porch's mouth, or on a doline's rim, looking in.
    var start := Vector3(0, 2.5, -8) if placement.profile.entrance_type != "shaft" \
        else Vector3(0, 6, -placement.profile.entrance_width_m * 0.5 - 6)
    player.transform = frame * Transform3D(Basis(Vector3.UP, PI), start)
    player.camera_pivot.rotation = Vector3.ZERO
    player.call_deferred("server_teleport_to", body, player.position)
    _update_collision_residency()


func _orbit_view() -> void:
    if _busy:
        return
    _clear_placement_pins()
    _picker.stop()
    _placement_light.hide()
    _place_hint.hide()
    player.god_mode = true
    flight_speed = 1000000.0
    _speeds.select(SPEEDS.size() - 1)
    _anchor = Vector3.ZERO
    _update_system_frame()
    player.position = Vector3(0.0, body.planet_data.radius * 0.6, body.planet_data.radius * 2.5)
    player.look_at(body.global_position, Vector3.UP)
    player.camera_pivot.rotation = Vector3.ZERO
    player.call_deferred("server_teleport_to", body, player.position)


func _place_here(add_new: bool = false) -> void:
    if _busy:
        return
    _busy = true
    _placement_button.disabled = true
    player.process_mode = Node.PROCESS_MODE_DISABLED
    _hint.text = "Chargement des tuiles et validation du raccord…"
    var proposed := CavePlacement.new()
    proposed.format_version = 2
    proposed.placement_id = placement.placement_id if placement and not add_new else "site-" + str(Time.get_ticks_usec())
    if add_new:
        var existing_ids := collection.sites.map(func(site: CavePlacement): return site.placement_id)
        while existing_ids.has(proposed.placement_id):
            proposed.placement_id += "x"
    proposed.resource_name = _site_name.text.strip_edges()
    if proposed.resource_name.is_empty() or (add_new and placement and proposed.resource_name == placement.resource_name):
        var number := collection.sites.size() + 1 if add_new or placement == null else collection.sites.find(placement) + 1
        proposed.resource_name = "Grotte %d" % number
    proposed.planet_name = selected_key
    proposed.longitude_deg = _longitude.value
    proposed.latitude_deg = _latitude.value
    proposed.heading_deg = _heading.value
    proposed.profile = _draft_profile.duplicate(true)
    proposed.seed = _draft_seed
    proposed.cover_m = maxf(2.0, proposed.profile.chamber_height_m * 0.15)
    proposed.ramp_length_m = 20.0
    proposed.planet_radius_m = body.planet_data.radius
    proposed.terrain_version = body.planet_data.chunk_data_version
    _population.cancelled = false
    var prepared := await _population.prepare_site(body.planet_data, proposed)
    var error := str(prepared.error)
    if error.is_empty():
        var staged: CaveSiteCollection = collection.duplicate(true)
        staged.put(proposed)
        error = CavePlanetRegistry.placements_error(_current_sites(selected_key, body.planet_data, staged), body.planet_data)
    if error.is_empty():
        var next: CaveSiteCollection = collection.duplicate(true)
        next.put(proposed)
        if _save_collection(next) == OK:
            _undo_collection = null
            collection = next
            placement = collection.selected()
            _hint.text = "Grotte ajoutée et essais sauvegardés." if add_new else "Grotte mise à jour et essais sauvegardés."
        else:
            error = "Impossible d’enregistrer le placement."
    _busy = false
    _placement_button.disabled = false
    if error.is_empty():
        await _rebuild_sites(selected_key)
        _sync_sites()
    else:
        player.process_mode = Node.PROCESS_MODE_INHERIT
        _hint.text = error


func _suggest_uphill_heading() -> void:
    if _busy:
        return
    _busy = true
    _hint.text = "Lecture du relief dans huit directions…"
    var origin := CavePlacement.new()
    origin.format_version = 2
    origin.profile = _draft_profile.duplicate(true)
    origin.longitude_deg = _longitude.value
    origin.latitude_deg = _latitude.value
    origin.planet_radius_m = body.planet_data.radius
    var data := body.planet_data
    var probes := CaveTerrainFit.heading_probes(origin)
    var deadline := Time.get_ticks_msec() + 45000
    var ready := false
    while Time.get_ticks_msec() < deadline:
        ready = true
        for probe in probes:
            if not CavePlanetRegistry.tiles_ready(data, probe):
                ready = false
        if ready:
            break
        await get_tree().create_timer(0.1).timeout
    if ready:
        var direction := origin.surface_direction()
        var height := data.crack_aware_surface_dist(direction, data.export_nside) - data.radius
        for probe in probes:
            probe.surface_height_m = height
        var suggestion := CaveTerrainFit.uphill_heading(data, probes)
        if float(suggestion.rise_m) > 2.0:
            _heading.value = suggestion.heading
            _hint.text = "Orientation proposée : %.0f°. Le relief monte d’environ %.1f m. Validez ensuite le placement." \
                % [suggestion.heading, suggestion.rise_m]
        else:
            _hint.text = "Peu de relief montant à cet endroit. Choisissez un pied de montagne ou gardez l’orientation actuelle."
    else:
        _hint.text = "Les tuiles du relief n’ont pas pu être chargées."
    _busy = false


func _open_workbench() -> void:
    _release_controls()
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    _workbench.edit_definition(_draft_profile, _draft_seed)


func _select_definition(profile: CaveProfile, cave_seed: int) -> void:
    _draft_profile = profile.duplicate(true)
    _draft_seed = cave_seed
    var built := _workbench.built_profile
    var library_changed := built != null and built.asset_library != profile.asset_library
    if built == null or library_changed or built.snapshot(_workbench.built_seed) != profile.snapshot(cave_seed):
        _workbench.edit_definition(profile, cave_seed, false)
    _draft_label.text = "Définition : %s • graine %d\n%.0f m • %d salles • passage %.1f × %.1f m" % [
        profile.display_name, cave_seed, profile.length_m, profile.chamber_count,
        profile.tunnel_width_m, profile.tunnel_height_m]
    if profile.asset_library:
        _draft_label.text += "\nDécors : " + profile.asset_library.display_name
    _hint.text = "Choisissez les coordonnées puis ajoutez un site, ou mettez à jour la grotte sélectionnée. " \
        + "Les essais sont sauvegardés automatiquement."


func export_placement(path: String) -> Error:
    if _busy or placement == null:
        return ERR_UNCONFIGURED
    # Export the last validated site, never an unplaced workbench draft.
    var data: PlanetData = (_system_bodies[placement.planet_name] as Planet).planet_data
    if not placement.validation_error(data).is_empty():
        return ERR_INVALID_DATA
    return CaveAuthoringFile.save(placement.duplicate(true), path)


func _choose_export() -> void:
    if _busy or placement == null:
        return
    _export_dialog.current_file = placement.placement_id + ".tres"
    _export_catalog = false
    _export_dialog.popup_centered_ratio(0.7)


func export_catalog(path: String) -> Error:
    if _busy:
        return ERR_BUSY
    var catalog := CaveSiteCatalog.new()
    catalog.sites = collection.on_body(selected_key)
    if not CavePlanetRegistry.placements_error(catalog.sites, body.planet_data).is_empty():
        return ERR_INVALID_DATA
    if catalog.sites.is_empty():
        return ERR_INVALID_DATA
    return CaveAuthoringFile.save(catalog, path)


func _choose_catalog_export() -> void:
    if _busy:
        return
    _export_catalog = true
    _export_dialog.title = "Exporter toutes les grottes de cette planète pour Dying Star"
    _export_dialog.current_file = selected_key + "_grottes.tres"
    _export_dialog.popup_centered_ratio(0.7)


func _apply_asset_library(all_on_body: bool = false) -> void:
    if _busy:
        return
    var library := _workbench.selected_library()
    if library == null or not library.validation_error().is_empty():
        _hint.text = "Choisissez une bibliothèque valide dans Création."
        return
    var next := collection.with_library(selected_key, library, not all_on_body)
    var count := 0
    for index in collection.sites.size():
        if next.sites[index] != collection.sites[index]:
            count += 1
    if count == 0:
        _hint.text = "Aucune grotte de cette famille à habiller dans la sélection."
        return
    if _save_collection(next) != OK:
        _hint.text = "Habillage non sauvegardé ; les grottes sont conservées."
        return
    _undo_collection = collection
    _undo_body = selected_key
    collection = next
    placement = collection.selected()
    await _rebuild_sites(selected_key)
    _sync_sites()
    if placement:
        _select_definition(placement.profile, placement.seed)
    _hint.text = "%d grotte(s) habillée(s) avec %s. Formes et positions conservées ; action annulable." % [count, library.display_name]


func _refit_planet() -> void:
    if _busy:
        return
    _busy = true
    _batch_cancel.disabled = false
    player.process_mode = Node.PROCESS_MODE_DISABLED
    var report := await _population.refit(body.planet_data, collection.on_body(selected_key))
    if not bool(report.cancelled) and not report.sites.is_empty():
        var next: CaveSiteCollection = collection.duplicate(true)
        for site: CavePlacement in report.sites:
            # Only publish a refit if it also respects neighbouring caves.
            var others: Array[CavePlacement] = next.on_body(selected_key).filter(
                func(other: CavePlacement): return other.placement_id != site.placement_id \
                    and other.validation_error(body.planet_data).is_empty())
            others.append(site)
            var error := CavePlanetRegistry.placements_error(others, body.planet_data)
            if error.is_empty():
                var selection := next.selected_id
                next.put(site)
                next.selected_id = selection
            else:
                report.rejected[site.placement_id + " : " + error] = 1
        if _backup_collection() == OK and _save_collection(next) == OK:
            _undo_collection = collection
            _undo_body = selected_key
            collection = next
            placement = collection.selected()
            if placement:
                _select_definition(placement.profile, placement.seed)
            await _rebuild_sites(selected_key)
            _batch_status.text = "Recalage sauvegardé. Les sites refusés sont conservés pour correction.\n" + str(report.rejected)
        else:
            _batch_status.text = "Recalage non sauvegardé ; les essais précédents sont conservés."
    else:
        _batch_status.text = "Recalage annulé ou aucun site accepté.\n" + str(report.rejected)
    _batch_cancel.disabled = true
    player.process_mode = Node.PROCESS_MODE_INHERIT
    _busy = false
    _sync_sites()


func _generate_planet() -> void:
    if _busy:
        return
    _busy = true
    _batch_button.disabled = true
    _batch_cancel.disabled = false
    player.process_mode = Node.PROCESS_MODE_DISABLED
    var replace := _batch_replace.button_pressed
    var existing: Array[CavePlacement] = []
    if not replace:
        existing = collection.on_body(selected_key)
    var report := await _population.generate(body.planet_data, existing,
        int(_batch_count.value), int(_batch_seed.value))
    _batch_cancel.disabled = true
    var added: Array = report.sites
    if bool(report.get("cancelled", false)):
        _batch_status.text = "Génération annulée. Aucun changement dans la collection."
    elif added.is_empty():
        _batch_status.text = "Aucun site ajouté. " + str(report.get("error", "")) + "\n" + str(report.rejected)
    else:
        var next: CaveSiteCollection = collection.duplicate(true)
        if replace:
            next.remove_on_body(selected_key)
        for site: CavePlacement in added:
            next.sites.append(site)
        next.selected_id = added[0].placement_id
        var summary := report.duplicate()
        summary.erase("sites")
        summary["accepted"] = added.size()
        next.set_meta("last_generation_report", summary)
        if _save_collection(next) == OK:
            _undo_collection = collection if replace else null
            _undo_body = selected_key
            collection = next
            placement = collection.selected()
            _select_definition(placement.profile, placement.seed)
            await _rebuild_sites(selected_key)
            _sync_sites()
            _batch_status.text = "%d / %d grottes ajoutées et sauvegardées. Accessibilité variable.\n%s" % [
                added.size(), int(report.requested),
                "Rejets : " + str(report.rejected) if not report.rejected.is_empty() else "Tous les sites proposés ont été validés."]
            if not str(report.error).is_empty():
                _batch_status.text += "\n" + str(report.error)
        else:
            _batch_status.text = "Sauvegarde impossible. La collection précédente est conservée."
    player.process_mode = Node.PROCESS_MODE_INHERIT
    _busy = false
    _batch_button.disabled = false
    _sync_sites()


func _save_collection(next: CaveSiteCollection) -> Error:
    return next.save_to(collection_path) if _load_error.is_empty() else ERR_INVALID_DATA


func _rebuild_sites(key: String, destination: String = "") -> void:
    # Keep native streaming resources alive and update the affected body at a worker checkpoint.
    _busy = true
    player.process_mode = Node.PROCESS_MODE_DISABLED
    var affected: Planet = _system_bodies[key]
    await affected.planet_terrain.refresh_stargrot_sites(_current_sites(key, affected.planet_data))
    if selected_key == key:
        await collision_terrain.refresh_stargrot_sites(_current_sites(key, affected.planet_data))
    player.process_mode = Node.PROCESS_MODE_INHERIT
    _busy = false
    var target := destination if not destination.is_empty() else key
    if _keep_view:
        _pin_placement()
        _update_collision_residency()
        return
    if target != selected_key:
        await _load_body(target)
    elif placement and placement.planet_name == target:
        _return_to_entrance()
    else:
        _orbit_view()


func _sync_sites() -> void:
    _site_list.clear()
    for site in collection.sites:
        var label := site.resource_name if not site.resource_name.is_empty() else site.placement_id
        var props := SystemScenes.body_properties("tarsis", site.planet_name)
        var data: PlanetData = _system_bodies[site.planet_name].planet_data
        if not site.validation_error(data).is_empty():
            label += " [à recaler]"
        _site_list.add_item(label + " • " + str(props.get("display_name", site.planet_name)))
        if site == placement:
            _site_list.select(_site_list.item_count - 1)
    _site_name.text = placement.resource_name if placement else ""
    _delete_button.disabled = placement == null
    _delete_all_button.disabled = collection.on_body(selected_key).is_empty()
    _placement_button.disabled = placement == null
    _undo_button.disabled = _undo_collection == null
    _copy_button.disabled = placement == null


func _visit_site(index: int) -> void:
    if _busy or index < 0 or index >= collection.sites.size():
        return
    var next: CaveSiteCollection = collection.duplicate(true)
    next.selected_id = next.sites[index].placement_id
    if _save_collection(next) != OK:
        _hint.text = "Impossible de sauvegarder la sélection ; les essais sont conservés."
        return
    # Keep current geometry/worker resources intact: selecting a site never rebuilds terrain.
    collection.selected_id = next.selected_id
    placement = collection.selected()
    _select_definition(placement.profile, placement.seed)
    if selected_key != placement.planet_name:
        await _load_body(placement.planet_name)
    else:
        _longitude.value = placement.longitude_deg
        _latitude.value = placement.latitude_deg
        _heading.value = placement.heading_deg
        _return_to_entrance()
    _sync_sites()
    _hint.text = "Grotte sélectionnée. Cliquez dans la vue planétaire pour l’explorer."


func _cycle_site(offset: int) -> void:
    if collection.sites.is_empty():
        return
    var current := collection.sites.find(placement)
    _visit_site(posmod(current + offset, collection.sites.size()))


func _delete_selected() -> void:
    await _delete_sites(false)


func _delete_all_on_body() -> void:
    await _delete_sites(true)


func _delete_sites(all_on_body: bool) -> void:
    if _busy or (not all_on_body and placement == null):
        return
    var affected_key := selected_key if all_on_body else placement.planet_name
    if all_on_body and collection.on_body(affected_key).is_empty():
        return
    var next: CaveSiteCollection = collection.duplicate(true)
    if all_on_body:
        next.remove_on_body(affected_key)
    else:
        next.remove_selected()
    if _save_collection(next) != OK:
        _hint.text = "Suppression impossible : les essais n’ont pas pu être sauvegardés."
        return
    _undo_collection = collection
    _undo_body = affected_key
    collection = next
    placement = collection.selected()
    if placement:
        _select_definition(placement.profile, placement.seed)
    await _rebuild_sites(affected_key, placement.planet_name if placement else selected_key)
    _sync_sites()
    _hint.text = "Grotte supprimée ; le terrain et ses collisions sont rétablis. Vous pouvez annuler cette suppression."
    if all_on_body:
        _hint.text = "Toutes les grottes de cette planète sont supprimées. Vous pouvez annuler cette suppression."


func _undo_delete() -> void:
    if _busy or _undo_collection == null:
        return
    if _save_collection(_undo_collection) != OK:
        _hint.text = "Impossible de sauvegarder la restauration."
        return
    collection = _undo_collection
    _undo_collection = null
    placement = collection.selected()
    if placement:
        _select_definition(placement.profile, placement.seed)
    await _rebuild_sites(_undo_body if not _undo_body.is_empty() else selected_key,
        placement.planet_name if placement else selected_key)
    _sync_sites()
    _hint.text = "Dernière suppression ou remplacement annulé ; les essais sont sauvegardés."


## A clicked site can be outside the avatar's collision neighbourhood. The native
## zone/pins union keeps JUST this authoring target physical until exploration resumes.
func _pin_placement() -> void:
    _placement_pins.clear()
    if placement == null or placement.planet_name != selected_key:
        return
    var data := collision_terrain.planet_data
    var nside := data.collision_detail_nside()
    for tile: int in CavePlanetRegistry.site_tiles(data, placement, nside):
        _placement_pins.append("hp_n%d_p%d" % [nside, tile])
    collision_terrain.set_pinned_chunks(_placement_pins)


func _clear_placement_pins() -> void:
    _placement_pins.clear()
    if is_instance_valid(collision_terrain):
        collision_terrain.set_pinned_chunks(_placement_pins)


func _begin_surface_placement() -> void:
    _release_controls()
    if _busy:
        return
    _clear_placement_pins()
    player.god_mode = true
    # Near a site, raise a tactical camera; from orbit use the authored coordinates.
    var origin := CavePlacement.new()
    origin.format_version = 2
    origin.longitude_deg = _longitude.value
    origin.latitude_deg = _latitude.value
    origin.planet_radius_m = body.planet_data.radius
    if body.surface_altitude_of(player.global_position) < 2000:
        var lonlat := CaveSurfacePicker.coordinates(player.position)
        origin.longitude_deg = lonlat.x
        origin.latitude_deg = lonlat.y
    origin.profile = _draft_profile.duplicate(true)
    origin.seed = _draft_seed
    _busy = true
    _place_hint.show()
    _place_hint.text = "Chargement du terrain de placement…"
    _population.cancelled = false
    var ready := await _population._wait_tiles(body.planet_data, origin, true)
    _busy = false
    if not ready or _closing:
        _place_hint.text = "Terrain indisponible. Réessayez après son chargement."
        return
    var direction := origin.surface_direction()
    origin.surface_height_m = body.planet_data.crack_aware_surface_dist(direction, body.planet_data.export_nside) - body.planet_data.radius
    var frame := origin.surface_transform()
    _anchor = frame.origin
    _update_system_frame()
    player.transform = frame * Transform3D(Basis(Vector3.UP, PI), Vector3(0, 180, -140))
    player.camera_pivot.rotation = Vector3(-0.9, 0, 0)
    player.call_deferred("server_teleport_to", body, player.position)
    flight_speed = 35.0
    _update_collision_residency()
    _placement_light.show()
    _markers.hide()
    _markers._clear()
    _picker.begin(_draft_profile, _draft_seed, _heading.value)
    _place_hint.show()
    _workbench.hide()
    get_window().grab_focus()


func _place_from_cursor(point: Vector3, heading: float) -> void:
    if _busy:
        return
    var lonlat := CaveSurfacePicker.coordinates(point)
    _longitude.value = lonlat.x
    _latitude.value = lonlat.y
    _heading.value = heading
    _keep_view = true
    _place_hint.text = "Raccord au relief et sauvegarde de la grotte…"
    await _place_here(true)
    _keep_view = false
    _place_hint.text = _hint.text
    if placement and placement.geographic_lonlat().distance_to(lonlat) < 0.00001:
        _picker.show_placed()
    # Keep the tactical camera above the result; a fresh action begins the next placement.


func _capture_view() -> void:
    if _busy or _closing:
        return
    _release_controls()
    _clear_placement_pins()
    _picker.stop()
    _place_hint.hide()
    _placement_light.hide()
    get_window().grab_focus()
    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _coordinates_from_view() -> void:
    var direction := player.position.normalized()
    _longitude.value = rad_to_deg(atan2(-direction.z, direction.x))
    _latitude.value = rad_to_deg(asin(clampf(direction.y, -1.0, 1.0)))


func _make_ui() -> void:
    var layer := CanvasLayer.new()
    add_child(layer)
    _status = Label.new()
    _status.position = Vector2(24, 18)
    _status.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _status.add_theme_font_size_override("font_size", 20)
    layer.add_child(_status)
    var controls := Label.new()
    controls.position = Vector2(24, 92)
    controls.text = "G : God Mode   •   ZQSD / WASD : déplacement   •   Espace / Ctrl : haut / bas\n" \
        + "Molette : vitesse   •   Maj : accélérer   •   Début : entrée   •   O : orbite   •   L : lampe" \
        + "   •   P : repères   •   + / − : heure (lumière)\n" \
        + "Clic dans la vue : explorer • Échap : libérer la souris et rejoindre l’atelier"
    controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
    layer.add_child(controls)
    var actions := HBoxContainer.new()
    actions.position = Vector2(24, 162)
    actions.theme = CaveWorkbenchTheme.create()
    layer.add_child(actions)
    _button(actions, "Atelier", func(): _workbench.show_sites())
    _button(actions, "Placer une grotte", _begin_surface_placement)
    _place_hint = Label.new()
    _place_hint.position = Vector2(24, 220)
    _place_hint.add_theme_color_override("font_color", CaveWorkbenchTheme.ACCENT)
    _place_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
    layer.add_child(_place_hint)
    _place_hint.hide()
    _workbench = CaveWorkbench.new()
    _workbench.visible = false
    _workbench.definition_selected.connect(_select_definition)
    _workbench.focus_entered.connect(func():
        Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
        _release_controls())
    add_child(_workbench)
    _menu = _workbench
    # Use the second screen when available; the native window remains freely movable.
    if DisplayServer.get_name() != "headless":
        var screen := 1 if DisplayServer.get_screen_count() > 1 else 0
        var usable := DisplayServer.screen_get_usable_rect(screen)
        _workbench.position = usable.position + (usable.size - _workbench.size) / 2
    _picker = CaveSurfacePicker.new()
    add_child(_picker)
    _picker.accepted.connect(_place_from_cursor)
    _picker.cancelled.connect(func():
        _place_hint.hide()
        _placement_light.hide())
    var column := _workbench.site_controls
    _button(column, "Placer sur le terrain", _begin_surface_placement)
    var title := Label.new()
    title.text = "SITES D’ESSAI • sauvegarde automatique"
    column.add_child(title)
    _site_list = ItemList.new()
    _site_list.custom_minimum_size = Vector2(350, 130)
    _site_list.item_selected.connect(_visit_site)
    column.add_child(_site_list)
    var navigation := HBoxContainer.new()
    column.add_child(navigation)
    _button(navigation, "Précédente", func(): _cycle_site(-1))
    _button(navigation, "Suivante", func(): _cycle_site(1))
    _button(column, "Rejoindre la grotte sélectionnée", _return_to_entrance)
    _button(column, "Habiller cette grotte avec la bibliothèque choisie", _apply_asset_library)
    _button(column, "Habiller les grottes de cette famille sur la planète", _apply_asset_library.bind(true))
    _delete_button = _button(column, "Supprimer la grotte sélectionnée", _delete_selected)
    _delete_all_button = _button(column, "Supprimer toutes les grottes de cette planète", _delete_all_on_body)
    _undo_button = _button(column, "Annuler la dernière suppression / remplacement", _undo_delete)
    _site_name = LineEdit.new()
    _site_name.placeholder_text = "Nom du site d’essai"
    column.add_child(_site_name)
    _draft_label = Label.new()
    _draft_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(_draft_label)
    _planets = OptionButton.new()
    for filename in bodies:
        var key := filename.get_basename()
        var props := SystemScenes.body_properties("tarsis", key)
        _planets.add_item(str(props.get("display_name", key)))
        if key == "tarsis_3":
            _planets.select(_planets.item_count - 1)
    _planets.item_selected.connect(func(index: int):
        if _busy:
            _planets.select(bodies.find(selected_key + ".tscn"))
        else:
            await _load_body(bodies[index].get_basename()))
    column.add_child(_planets)
    column = _workbench.population_controls
    var batch_title := Label.new()
    batch_title.text = "PEUPLER LA PLANÈTE AUTOMATIQUEMENT"
    column.add_child(batch_title)
    _batch_count = _coordinate(column, "Nombre à ajouter", 1, 512)
    _batch_count.step = 1
    _batch_count.value = 200
    _batch_seed = _coordinate(column, "Graine du lot", 0, 2147483647)
    _batch_seed.step = 1
    _batch_seed.value = 20261005
    _batch_replace = CheckButton.new()
    _batch_replace.text = "Remplacer les essais de cette planète (annulable)"
    column.add_child(_batch_replace)
    _button(column, "Recaler les grottes sur le relief actuel", _refit_planet)
    _batch_button = _button(column, "Générer les grottes sur cette planète", _generate_planet)
    _batch_cancel = _button(column, "Annuler la génération en cours", func(): _population.cancelled = true)
    _batch_cancel.disabled = true
    _batch_status = Label.new()
    _batch_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _batch_status.text = "Répartition guidée par les biomes et le relief. Ouvertures naturelles et puits ; aucun quota d’accès piéton."
    column.add_child(_batch_status)
    _population = CavePopulation.new()
    _population.progress.connect(func(accepted: int, requested: int, attempted: int, message: String):
        _batch_status.text = "%d / %d validées • %d propositions\n%s" % [accepted, requested, attempted, message])
    add_child(_population)
    column = _workbench.site_controls
    _longitude = _coordinate(column, "Longitude", -180.0, 180.0)
    _latitude = _coordinate(column, "Latitude", -90.0, 90.0)
    _heading = _coordinate(column, "Orientation", -180.0, 180.0)
    _button(column, "Orienter vers le relief montant", _suggest_uphill_heading)
    _button(column, "Reprendre les coordonnées de la vue", _coordinates_from_view)
    _add_button = _button(column, "Ajouter une nouvelle grotte ici", func(): _place_here(true))
    _placement_button = _button(column, "Mettre à jour la grotte sélectionnée", _place_here)
    _hint = Label.new()
    _hint.custom_minimum_size.x = 350
    _hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(_hint)
    var note := Label.new()
    note.text = ("Les ajouts et suppressions sont conservés au prochain lancement.\n"
        + "Jusqu’à 512 sites par planète ; géométrie chargée avec les secteurs proches du terrain.")
    note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(note)
    column = _workbench.delivery_controls
    var delivery_title := Label.new()
    delivery_title.text = "VOS GROTTES DANS DYING STAR"
    delivery_title.add_theme_color_override("font_color", CaveWorkbenchTheme.ACCENT)
    column.add_child(delivery_title)
    _copy_button = _button(column, "Copier ce site pour Dying Star… (facultatif)", _choose_export)
    _button(column, "Exporter toutes les grottes de cette planète…", _choose_catalog_export)
    var help := Label.new()
    help.text = "1. Exportez le catalogue de la planète.\n\n" \
        + "2. Ajoutez-le au dossier levels/stargrot/catalogs de develop.\n\n" \
        + "3. Affectez-le au champ Cave Catalog du PlanetData de cette planète, puis livrez les deux fichiers.\n\n" \
        + "Le jeu charge les grottes avec ses secteurs de terrain. L’atelier reste un outil séparé.\n\n" \
        + "Le module de grottes doit être intégré une première fois. Consultez STARGROT-LIVRAISON-DEVELOP.md."
    help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(help)
    column = _workbench.view_controls
    _button(column, "Explorer dans la vue planétaire", _capture_view)
    _button(column, "Activer / quitter le God Mode", _toggle_flight)
    _button(column, "Revenir à l’entrée sélectionnée", _return_to_entrance)
    _button(column, "Voir la planète depuis l’orbite", _orbit_view)
    _button(column, "Avancer de 6 heures locales (jour / nuit)", func(): _shift_time(6.0))
    _speeds = OptionButton.new()
    for speed in SPEEDS:
        _speeds.add_item("Vitesse de vol : %s m/s" % str(speed))
    _speeds.item_selected.connect(func(index: int): flight_speed = SPEEDS[index])
    column.add_child(_speeds)
    _export_dialog = FileDialog.new()
    _export_dialog.access = FileDialog.ACCESS_FILESYSTEM
    _export_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
    _export_dialog.title = "Créer une copie du site sélectionné pour l’intégration à Dying Star"
    _export_dialog.filters = PackedStringArray(["*.tres ; Site planétaire pour Dying Star"])
    _export_dialog.current_dir = ProjectSettings.globalize_path("res://levels/stargrot")
    _export_dialog.file_selected.connect(func(path: String):
        var error := export_catalog(path) if _export_catalog else export_placement(path)
        _hint.text = "Export enregistré : " + path if error == OK else "Échec de l’export.")
    _workbench.add_child(_export_dialog)


func _button(parent: Node, text: String, action: Callable) -> Button:
    var button := Button.new()
    button.text = text
    button.pressed.connect(action)
    parent.add_child(button)
    return button


func _coordinate(parent: Node, label: String, minimum: float, maximum: float) -> SpinBox:
    var row := HBoxContainer.new()
    var name_label := Label.new()
    name_label.text = label
    name_label.custom_minimum_size.x = 160
    row.add_child(name_label)
    var control := SpinBox.new()
    control.min_value = minimum
    control.max_value = maximum
    control.step = 0.0000001
    control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(control)
    parent.add_child(row)
    return control
