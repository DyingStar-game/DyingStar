extends Node
## Place a modern multi-level cave on real Tarsis tiles, export and stand on every storey.

const SESSION_PATH := "user://stargrot_test_creative_planet.tres"
var checks: int = 0
var failures: Array[String] = []


func _ready() -> void:
    preload("res://test/stargrot/test_cache.gd").use_directory("StarGrotteTests")
    print("CREATIVE TEST USER DIR ", OS.get_user_data_dir())
    _run.call_deferred()


func check(condition: bool, label: String) -> void:
    checks += 1
    if not condition:
        failures.append(label)
        push_error(label)


func _run() -> void:
    check(CaveSiteCollection.new().save_to(SESSION_PATH) == OK, "isolated empty test session")
    var explorer = load("res://levels/stargrot/stargrot_explorer.tscn").instantiate()
    explorer.placement_path = "user://stargrot_test_creative_missing_legacy.tres"
    explorer.collection_path = SESSION_PATH
    add_child(explorer)
    await get_tree().process_frame  # finish the launcher's deferred opening before editing
    print("CREATIVE STAGE preview")
    var workbench: CaveWorkbench = explorer._workbench
    var profile := CaveWorkbench.preset(1)
    profile.generator_version = CaveGenerator.VERSION
    profile.length_m = 180.0
    profile.level_count = 3
    profile.depth_m = 38.0
    profile.chamber_width_m = 32.0
    profile.chamber_height_m = 14.0
    profile.entrance_type = "hangar"
    profile.entrance_width_m = 15.0
    profile.entrance_height_m = 12.0
    profile.exit_open = true
    profile.asset_library = load("res://scenes/planet/cave/libraries/cave_rock_open.tres")
    workbench.edit_definition(profile, 7654321)
    var deadline := Time.get_ticks_msec() + 20000
    while workbench._task >= 0 and Time.get_ticks_msec() < deadline:
        await get_tree().process_frame
    check(not workbench.data.is_empty() and workbench.built_profile.level_count == 3, "workbench builds three stacked levels")
    var authored_faces: PackedVector3Array = workbench.data.faces.duplicate()
    var authored_spec: Dictionary = workbench.data.spec.duplicate(true)
    workbench._cutaway = true
    workbench._refresh_preview()
    workbench._yaw = PI * 0.5
    workbench._pitch = 0.3
    workbench._distance *= 0.75
    workbench._orbit()
    await _draw_frame()
    await _draw_frame()
    if DisplayServer.get_name() != "headless":
        workbench.get_texture().get_image().save_png("res://.stargrot-validation/creative-levels.png")
    workbench._cutaway = false
    workbench._refresh_preview()
    var first_room: Dictionary = workbench.data.graph.rooms[0]
    workbench._target = first_room.a + Vector3.UP * 3.0
    workbench._distance = 16.0
    workbench._yaw = 0.5
    workbench._pitch = 0.18
    workbench._orbit()
    await _draw_frame()
    if DisplayServer.get_name() != "headless":
        workbench.get_texture().get_image().save_png("res://.stargrot-validation/creative-pillars.png")
    var cathedral := CaveWorkbench.preset(3)
    workbench.edit_definition(cathedral, 81)
    deadline = Time.get_ticks_msec() + 20000
    while workbench._task >= 0 and Time.get_ticks_msec() < deadline:
        await get_tree().process_frame
    check(not workbench.data.is_empty() and workbench.data.graph.bridges.size() > 0, "cathedral preview includes a rock bridge")
    if not workbench.data.is_empty() and not workbench.data.graph.bridges.is_empty():
        var bridge: Dictionary = workbench.data.graph.bridges[0]
        workbench._target = (bridge.a + bridge.b) * 0.5 + Vector3.UP * 3
        workbench._distance = bridge.room.size.x * 0.8
        workbench._yaw = 0.5
        workbench._pitch = 0.22
        workbench._orbit()
        await _draw_frame()
        await _draw_frame()
        if DisplayServer.get_name() != "headless":
            workbench.get_texture().get_image().save_png("res://.stargrot-validation/creative-bridge.png")
    workbench.edit_definition(profile, 7654321)
    deadline = Time.get_ticks_msec() + 20000
    while workbench._task >= 0 and Time.get_ticks_msec() < deadline:
        await get_tree().process_frame
    workbench.select_definition()
    print("CREATIVE STAGE placement")
    var reference: CavePlacement = load("res://levels/stargrot/initial_cave.tres")
    explorer._longitude.value = reference.geographic_lonlat().x
    explorer._latitude.value = reference.latitude_deg
    explorer._heading.value = reference.heading_deg
    await explorer._place_here(true)
    deadline = Time.get_ticks_msec() + 60000
    while Time.get_ticks_msec() < deadline:
        var registry: CavePlanetRegistry = explorer.collision_terrain.stargrot_registry
        if not explorer._busy and registry and registry.prepared and registry.residency_stats().resident == 1:
            break
        await get_tree().create_timer(0.1).timeout
    check(explorer.collection.sites.size() == 1, "modern site accepted on real terrain: " + explorer._hint.text)
    if explorer.placement:
        var site: CavePlacement = explorer.placement
        var registry: CavePlanetRegistry = explorer.collision_terrain.stargrot_registry
        check(registry and registry.prepared and registry.error_message.is_empty(), "native collision registry accepts site")
        check(site.profile.generator_version == CaveGenerator.VERSION and site.profile.level_count == 3,
            "placement retains generator version and storeys")
        check(site.fitted_mouth_depth_m >= 0.0 and site.portal_axis_m > 0.0, "relief-fitted entrance pinned in placement")
        var plans: Array = explorer.collision_terrain.planet_data.stargrot_plans
        check(plans.size() == 1, "server builds shared plan")
        if not plans.is_empty():
            var cave: Dictionary = plans[0].cave
            check(cave.spec == authored_spec, "native plan retains authored snapshot")
            # Compare all corresponding metre coordinates across worker/renderer contexts.
            var max_difference := 0.0
            for index in mini(cave.faces.size(), authored_faces.size()):
                max_difference = maxf(max_difference, cave.faces[index].distance_to(authored_faces[index]))
            print("STARGROT COORDINATE DELTA %.18f m" % max_difference)
            check(cave.faces.size() == authored_faces.size() and max_difference <= 1.0e-9,
                "authoring and server coordinates agree within one nanometre")
            explorer.set_physics_process(false)
            explorer.player.input_direction = Vector2.ZERO
            explorer.player.god_mode = false
            for level in 3:
                var room := _room_on_level(cave, level)
                if room.is_empty():
                    continue
                var target: Vector3 = site.cave_transform() * _standing_point(cave, room)
                print("CREATIVE PLAYER level=", level, " local=", site.cave_transform().affine_inverse() * target)
                explorer.player.process_mode = Node.PROCESS_MODE_DISABLED
                explorer.player.transform = Transform3D(site.surface_transform().basis, target)
                explorer.player.velocity = Vector3.ZERO
                explorer.player.call_deferred("server_teleport_to", explorer.body, target)
                await get_tree().physics_frame
                await get_tree().physics_frame
                explorer.player.process_mode = Node.PROCESS_MODE_INHERIT
                await get_tree().create_timer(0.6).timeout
                print("CREATIVE PLAYER settled level=", level)
                check(explorer.player.position.distance_to(target) < 3.0, "player stays on storey %d without surface rescue" % level)
                check(CavePlanetRegistry.contains(explorer.collision_terrain.planet_data, explorer.player.position),
                    "physical storey containment %d" % level)
            explorer._return_to_entrance()
            var photo_position := site.surface_transform() * Vector3(0, 35, -8)
            explorer.player.call_deferred("server_teleport_to", explorer.body, photo_position)
            await get_tree().physics_frame
            await get_tree().physics_frame
            explorer.player.look_at(explorer.body.to_global(site.surface_transform() * Vector3(0, -6, 8)),
                site.surface_transform().basis.z)
            explorer._inspection_light.light_energy = 2.0
            explorer._inspection_light.omni_range = 80
            explorer._workbench.hide()
            await _draw_frame()
            await _draw_frame()
            if DisplayServer.get_name() != "headless":
                explorer.get_viewport().get_texture().get_image().save_png("res://.stargrot-validation/creative-mouth.png")
        var export_path := "user://stargrot_test_creative_export.tres"
        check(explorer.export_placement(export_path) == OK, "game site exports")
        var restored: CavePlacement = ResourceLoader.load(export_path, "", ResourceLoader.CACHE_MODE_IGNORE)
        check(restored and restored.profile.asset_library.library_id == "rock_open_v1", "export retains mouth palette")
        check(restored and restored.signature() == site.signature(), "export retains terrain signature")
        DirAccess.remove_absolute(ProjectSettings.globalize_path(export_path))
    print("CREATIVE STAGE population")
    explorer._batch_count.value = 10
    explorer._batch_seed.value = 20261005
    explorer._population.progress.connect(func(accepted: int, requested: int, attempted: int, message: String):
        print("TARSIS BATCH ", accepted, "/", requested, " attempts=", attempted, " ", message))
    explorer.set_physics_process(true)
    await explorer._generate_planet()
    check(explorer.collection.sites.size() == 11, "one-click native Tarsis batch: " + explorer._batch_status.text)
    check(not explorer._busy and explorer._batch_cancel.disabled and not explorer._batch_button.disabled, "batch controls restored")
    var catalog_path := "user://stargrot_test_native_catalog.tres"
    check(explorer.export_catalog(catalog_path) == OK, "native batch catalog exports")
    var catalog: CaveSiteCatalog = ResourceLoader.load(catalog_path, "", ResourceLoader.CACHE_MODE_IGNORE)
    check(catalog and catalog.sites.size() == explorer.collection.sites.size(), "catalog contains every planetary site")
    DirAccess.remove_absolute(ProjectSettings.globalize_path(catalog_path))
    print("CREATIVE STAGE export/refit")
    if "--stargrot-delivery-catalog" in OS.get_cmdline_user_args():
        DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://levels/stargrot/catalogs"))
        check(explorer.export_catalog("res://levels/stargrot/catalogs/tarsis_3_example.tres") == OK, "delivery catalog validates")
        check(ResourceSaver.save(explorer.collection.sites[0], "res://levels/stargrot/initial_cave.tres") == OK,
            "current initial site saves")
    # Simulate an old trial, then exercise the actual tool refit/save/rebuild path.
    var original: CavePlacement = explorer.collection.sites[0]
    var legacy: CavePlacement = original.duplicate(true)
    legacy.longitude_deg = -original.longitude_deg
    legacy.format_version = 1
    legacy.terrain_version = "old-relief"
    legacy.surface_height_m += 25.0
    var direction := legacy.surface_direction()
    explorer.collection.sites[0] = legacy
    await explorer._refit_planet()
    var fitted: CavePlacement = explorer.collection.sites[0]
    check(fitted.format_version == 2 and fitted.terrain_version == explorer.body.planet_data.chunk_data_version,
        "legacy trial refits on current native relief")
    check(fitted.surface_direction().distance_to(direction) < 0.000001, "refit preserves physical longitude")
    check(explorer.collection.sites.size() == 11 and explorer._undo_collection != null, "refit keeps all trials and supports undo")
    check(explorer.export_catalog(catalog_path) == OK, "refitted native catalog exports")
    DirAccess.remove_absolute(ProjectSettings.globalize_path(catalog_path))
    print("CREATIVE STAGE deletion/undo")
    var saved_id: String = explorer.placement.placement_id
    await explorer._delete_selected()
    check(explorer.collection.sites.size() == 10, "delete a generated site without deleting the batch")
    check(not explorer.collection.sites.any(func(site: CavePlacement): return site.placement_id == saved_id),
        "deleted identity removed")
    await explorer._undo_delete()
    check(explorer.collection.sites.size() == 11 and explorer.placement.placement_id == saved_id,
        "undo restores the same generated identity")
    check(explorer.collision_terrain.planet_data.cave_placements.size() == 11, "native terrain receives restored definitions")
    explorer._batch_count.value = 2
    explorer._batch_replace.button_pressed = true
    await explorer._generate_planet()
    check(explorer.collection.sites.size() == 2, "replace old trials in one atomic generation")
    await explorer._undo_delete()
    check(explorer.collection.sites.size() == 11, "undo restores the replaced planetary collection")
    await explorer._delete_all_on_body()
    check(explorer.collection.on_body(explorer.selected_key).is_empty(), "one-click deletion clears all planetary trials")
    check(explorer.collision_terrain.planet_data.cave_placements.is_empty(), "bulk deletion restores native terrain cuts")
    check(explorer.collision_terrain.stargrot_registry == null, "bulk deletion retires the cave registry")
    check(explorer._delete_all_button.disabled and not explorer._undo_button.disabled, "bulk deletion controls permit undo")
    await explorer._undo_delete()
    check(explorer.collection.sites.size() == 11, "undo restores bulk-deleted sites")
    check(explorer.collision_terrain.planet_data.cave_placements.size() == 11, "bulk undo restores terrain definitions")
    explorer._orbit_view()
    explorer.set_physics_process(true)
    await get_tree().create_timer(2.0).timeout
    check(explorer.collision_terrain.stargrot_registry.residency_stats().resident == 0, "orbital view unloads server cave")
    print("CREATIVE STAGE teardown")
    await explorer.shutdown()
    var cave_jobs := 0
    var cave_processing := false
    var closing_terrains: Array[PlanetTerrain] = [explorer.collision_terrain]
    for planet: Planet in explorer._system_bodies.values():
        closing_terrains.append(planet.planet_terrain)
    for terrain in closing_terrains:
        if terrain.stargrot_registry != null:
            cave_jobs += int(terrain.stargrot_registry.residency_stats().workers)
            cave_processing = cave_processing or terrain.stargrot_registry.is_processing()
    check(cave_jobs == 0, "closing joins cave workers before native resource teardown")
    check(not cave_processing, "retired registries cannot submit new jobs while closing")
    explorer.free()
    # Let deferred render releases finish while the main loop and rendering server still exist.
    await get_tree().process_frame
    RenderingServer.force_sync()
    DirAccess.remove_absolute(ProjectSettings.globalize_path(SESSION_PATH))
    var file := FileAccess.open("res://test/stargrot/creative-planet-results.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"checks": checks, "failures": failures}, "  "))
    file.close()
    print("STARGROT CREATIVE PLANET ", checks, " checks; failures=", failures)
    get_tree().quit(0 if failures.is_empty() else 1)


func _draw_frame() -> void:
    if DisplayServer.get_name() == "headless":
        await get_tree().process_frame
    else:
        await RenderingServer.frame_post_draw


## The largest chamber of a tier, or none.
func _room_on_level(cave: Dictionary, level: int) -> Dictionary:
    var best := {}
    for room: Dictionary in cave.graph.rooms:
        if int(room.level) == level and (best.is_empty() or float(room.size.x) > float(best.size.x)):
            best = room
    return best


## 1.2 m above the first floor found over a chamber's centre, in the cave's own frame.
func _standing_point(cave: Dictionary, room: Dictionary) -> Vector3:
    var height := -8.0
    while height < float(room.size.y):
        if float(cave.sampler.call("Sample", room.a + Vector3.UP * height)) > 0.0:
            break
        height += 0.1
    return room.a + Vector3.UP * (height + 1.2)
