extends Node
## End-to-end: actual Tarsis collision -> cursor click -> shared fitter -> saved catalogue.

var failures: Array[String] = []
var checks: int = 0


func _ready() -> void:
    preload("res://test/stargrot/test_cache.gd").use_directory("StarGrotteCursorTests")
    _run.call_deferred()


func check(ok: bool, label: String) -> void:
    checks += 1
    if not ok:
        failures.append(label)
        push_error(label)


func _run() -> void:
    var path := "user://cursor_sites.tres"
    CaveSiteCollection.new().save_to(path)
    var explorer = load("res://levels/stargrot/stargrot_explorer.tscn").instantiate()
    explorer.collection_path = path
    add_child(explorer)
    var reference: CavePlacement = load("res://levels/stargrot/initial_cave.tres")
    var profile := CaveWorkbench.preset(0)
    profile.bridge_count = 0
    profile.crawl_count = 0
    profile.asset_library = load("res://scenes/planet/cave/libraries/cave_rock_open.tres")
    explorer._select_definition(profile, 81)
    explorer._longitude.value = reference.geographic_lonlat().x
    explorer._latitude.value = reference.latitude_deg
    explorer._heading.value = 0
    await explorer._begin_surface_placement()
    await _check_authoring_input(explorer)
    var picker: CaveSurfacePicker = explorer._picker
    var deadline := Time.get_ticks_msec() + 60000
    while Time.get_ticks_msec() < deadline and not picker.valid:
        picker._next_update = 0
        picker.update_cursor(explorer.player.camera, explorer.body, explorer.collision_terrain,
            explorer.get_viewport().get_visible_rect().size * 0.5)
        if not picker.valid:
            await get_tree().create_timer(0.1).timeout
    check(picker.valid, "native loaded terrain selectable from tactical view")
    if picker.valid:
        var point := picker._point
        var camera_before: Transform3D = explorer.player.transform
        var click := InputEventMouseButton.new()
        click.pressed = true
        click.button_index = MOUSE_BUTTON_LEFT
        picker.handle_input(click)
        deadline = Time.get_ticks_msec() + 90000
        while explorer._busy and Time.get_ticks_msec() < deadline:
            await get_tree().create_timer(0.1).timeout
        check(not explorer._busy, "click placement completes within bounded time")
        check(explorer.collection.sites.size() == 1, "one click adds one cave: " + explorer._hint.text)
        if explorer.collection.sites.size() == 1:
            var site: CavePlacement = explorer.collection.sites[0]
            check(site.geographic_lonlat().distance_to(CaveSurfacePicker.coordinates(point)) < 0.00001,
                "saved coordinates match clicked surface")
            check(site.profile.generator_version == CaveGenerator.VERSION, "new click creates current natural form")
            check(explorer.player.position.distance_to(camera_before.origin) < 1,
                "placement keeps the overhead viewpoint")
            check(not explorer._placement_pins.is_empty(), "authoring target uses native collision pins")
            check(explorer.export_catalog("user://cursor_catalog.tres") == OK, "ready-to-integrate catalog exports")
            check(not FileAccess.get_file_as_string("user://cursor_catalog.tres").contains("tools/stargrot"),
                "exported content independent from authoring UI")
            var saved: CaveSiteCollection = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
            check(saved.sites.size() == 1, "click result persists on disk")
            deadline = Time.get_ticks_msec() + 45000
            while Time.get_ticks_msec() < deadline:
                if explorer.body.planet_terrain.stargrot_registry.residency_stats().resident > 0 \
                        and explorer.collision_terrain.stargrot_registry.residency_stats().resident > 0:
                    break
                await get_tree().create_timer(0.1).timeout
            check(explorer.collision_terrain.stargrot_registry.residency_stats().resident > 0,
                "clicked cave collision loaded through native residency")
            if DisplayServer.get_name() != "headless":
                await RenderingServer.frame_post_draw
                explorer.get_viewport().get_texture().get_image().save_png("res://../stargrot-placement-0.7.png")
            var geometry_before := site.signature()
            var library_before := site.profile.asset_library.library_id
            explorer._workbench._profile.asset_library = CaveAssetLibrary.default_for("rock", true)
            await explorer._apply_asset_library(false)
            check(explorer.placement.profile.asset_library.library_id == "rock_sculpted_open_v1",
                "existing cave receives the chosen real asset library")
            check(explorer.placement.signature() == geometry_before,
                "redressing preserves the validated geometry and placement")
            await explorer._undo_delete()
            check(explorer.placement.profile.asset_library.library_id == library_before,
                "redressing can be undone without deleting the cave")
            explorer._workbench.show_sites()
            if DisplayServer.get_name() != "headless":
                await RenderingServer.frame_post_draw
                explorer._workbench.get_texture().get_image().save_png("res://../stargrot-sites-0.7.png")
                explorer._workbench._tabs.current_tab = 3
                await RenderingServer.frame_post_draw
                explorer._workbench.get_texture().get_image().save_png("res://../stargrot-livraison-0.7.png")
            await explorer._delete_selected()
            check(explorer.collection.sites.is_empty(), "clicked cave can be removed")
            await explorer._undo_delete()
            check(explorer.collection.sites.size() == 1, "deletion can be undone")
            explorer._orbit_view()
            check(explorer._placement_pins.is_empty(), "orbital view releases authoring pins")
    await explorer.shutdown()
    explorer.free()
    var file := FileAccess.open("res://test/stargrot/surface-placement-results.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"checks": checks, "failures": failures}, "  "))
    file.close()
    print("STARGROT SURFACE PLACEMENT ", checks, " checks; failures=", failures)
    get_tree().quit(0 if failures.is_empty() else 1)


func _check_authoring_input(explorer) -> void:
    var before: Vector3 = explorer.player.position
    Input.action_press("move_right", 0.6)
    for frame in 4:
        await get_tree().physics_frame
    check(explorer.player.input_direction == Vector2.ZERO,
        "controller axis cannot steer tactical keyboard camera")
    check(explorer.player.input_from_server.get("frame", "missing") == PropSpawn.parent_frame_uuid(explorer.player),
        "atelier movement supplies the native player's current reference frame")
    check(explorer.player.position.distance_to(before) < 0.01,
        "native god-mode body stays still under controller drift")
    Input.action_release("move_right")
    explorer.player.input_direction = Vector2.RIGHT
    explorer.player.velocity = Vector3.RIGHT * 3.0
    explorer.get_window().focus_exited.emit()
    check(explorer.player.input_direction == Vector2.ZERO and explorer.player.velocity == Vector3.ZERO,
        "window focus loss immediately clears retained motion")
    explorer.player.input_direction = Vector2.RIGHT
    explorer.player.input_from_server.input_direction = Vector2.RIGHT
    explorer._busy = true
    explorer._physics_process(0.016)
    check(explorer.player.input_from_server.input_direction == Vector2.ZERO,
        "busy placement does not leave the server moving with old input")
    check(explorer.player.input_from_server.get("frame", "missing") == PropSpawn.parent_frame_uuid(explorer.player),
        "stopped input preserves the native player's reference frame")
    explorer._busy = false
