extends Node
## Capture the real authoring UI, including its independent 3D preview.


func _ready() -> void:
    _run.call_deferred()


func _run() -> void:
    get_viewport().gui_embed_subwindows = false
    var workbench: CaveWorkbench
    var explorer: Node
    if "--stargrot-workbench" in OS.get_cmdline_user_args():
        explorer = load("res://levels/stargrot/stargrot_explorer.tscn").instantiate()
        explorer.placement_path = "user://stargrot_test_visual_missing.tres"
        add_child(explorer)
        workbench = explorer._workbench
        await get_tree().process_frame
    else:
        workbench = CaveWorkbench.new()
        workbench.visible = false
        add_child(workbench)
        workbench.edit_definition(CaveWorkbench.preset(1), 104729)
    var deadline := Time.get_ticks_msec() + 20000
    while workbench._task >= 0 and Time.get_ticks_msec() < deadline:
        await get_tree().process_frame
    if workbench.data.is_empty():
        get_tree().quit(1)
        return
    await RenderingServer.frame_post_draw
    await RenderingServer.frame_post_draw
    workbench.get_texture().get_image().save_png("res://../stargrot-atelier-0.7.png")
    var native_ok := not workbench.is_embedded() and not workbench.transient and not workbench.exclusive
    if not explorer:
        workbench._inspect_assets()
        await RenderingServer.frame_post_draw
        await RenderingServer.frame_post_draw
        workbench.get_texture().get_image().save_png("res://../stargrot-apercu-decors.png")
        native_ok = native_ok and float(workbench.data.sampler.call("Sample", workbench._camera.position)) > 0.0
        print("STARGROT ASSET INSPECTION inside=", native_ok, " status=", workbench._status.text.replace("\n", " • "))
    if explorer:
        native_ok = native_ok and workbench.get_window_id() != explorer.get_window().get_window_id()
        workbench.show_sites()
        await RenderingServer.frame_post_draw
        await RenderingServer.frame_post_draw
        workbench.get_texture().get_image().save_png("res://../stargrot-sites-0.7.png")
        explorer.get_viewport().get_texture().get_image().save_png("res://../stargrot-vue-planetaire-0.7.png")
    print("STARGROT NATIVE WINDOWS independent=", native_ok,
        " windows=", DisplayServer.get_window_list(), " tool_position=", workbench.position)
    if explorer:
        await explorer.shutdown()
        var pending: int = explorer.collision_terrain.planet_data._grade_pending.size()
        for planet: Planet in explorer._system_bodies.values():
            pending += planet.planet_data._grade_pending.size()
        native_ok = native_ok and pending == 0
        var cave_pending := 0
        var cave_processing := false
        var terrains: Array[PlanetTerrain] = [explorer.collision_terrain]
        for planet: Planet in explorer._system_bodies.values():
            terrains.append(planet.planet_terrain)
        for terrain in terrains:
            if terrain.stargrot_registry != null:
                cave_pending += int(terrain.stargrot_registry.residency_stats().workers)
                cave_processing = cave_processing or terrain.stargrot_registry.is_processing()
        native_ok = native_ok and cave_pending == 0 and not cave_processing
        print("STARGROT STARTUP SHUTDOWN pending_grade_jobs=", pending,
            " pending_cave_jobs=", cave_pending, " cave_processing=", cave_processing)
        explorer.free()
    else:
        workbench.free()
    get_tree().quit(0 if native_ok else 1)
