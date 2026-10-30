extends GutTest
## Exercise the real tool callbacks and the same resources consumed by PlanetTerrain.

const Fixture := preload("res://test/unit/stargrot_fixture.gd")

var _workbench: CaveWorkbench


func before_each() -> void:
    _workbench = CaveWorkbench.new()
    _workbench.visible = false
    add_child_autofree(_workbench)


func _finish_generation() -> void:
    var deadline := Time.get_ticks_msec() + 10000
    while _workbench._task >= 0 and Time.get_ticks_msec() < deadline:
        await get_tree().process_frame
    assert_eq(_workbench._task, -1, "worker finishes")
    assert_false(_workbench.data.is_empty(), "preview uses real generated geometry")


func test_size_presets_and_seed_change_the_actual_rooms() -> void:
    var widths: Array[float] = []
    for index in 3:
        var profile := CaveWorkbench.preset(index)
        var cave := CaveGenerator.build(profile.snapshot(42))
        assert_eq(cave.error, "")
        var width: float = 0.0
        for room: Dictionary in cave.graph.rooms:
            width = maxf(width, room.size.x * 2.0)
        widths.append(width)
    assert_true(widths[0] < widths[1] and widths[1] < widths[2], "preset sizes affect generated geometry")
    var spec := CaveWorkbench.preset(1).snapshot(42)
    var original := CaveGenerator.build(spec)
    assert_eq(original.faces, CaveGenerator.build(spec).faces, "same seed is reproducible")
    spec.seed = 43
    assert_ne(original.faces, CaveGenerator.build(spec).faces, "another seed produces another cave")


func test_inspecting_a_version_8_site_keeps_its_geometry_until_explicit_regeneration() -> void:
    var profile := Fixture.profile(0)
    profile.generator_version = 8
    _workbench.edit_definition(profile, 4242, false)
    await _finish_generation()
    assert_eq(_workbench.data.spec, profile.snapshot(4242))
    assert_eq(_workbench.data.faces, CaveGenerator.build(profile.snapshot(4242)).faces)
    _workbench._fields.chamber_width_m.value = 20
    _workbench.generate()
    await _finish_generation()
    assert_eq(_workbench.built_profile.generator_version, CaveGenerator.VERSION)
    assert_eq(_workbench.data.spec.chamber_width_m, 20.0)


func test_random_button_and_selection_use_the_visible_snapshot() -> void:
    var source := CaveWorkbench.preset(0, "ice")
    _workbench.edit_definition(source, 123)
    await _finish_generation()
    var previous := _workbench.built_seed
    _workbench.randomize_definition()
    await _finish_generation()
    assert_eq(CaveGenerator.validation_error(_workbench.data.spec), "")
    assert_ne(_workbench.built_seed, previous)
    assert_eq(_workbench.built_profile.profile_id, "ice")
    watch_signals(_workbench)
    _workbench.select_definition()
    assert_signal_emitted(_workbench, "definition_selected")
    var parameters: Array = get_signal_parameters(_workbench, "definition_selected")
    assert_eq(parameters[0].snapshot(parameters[1]), _workbench.data.spec)
    assert_ne(parameters[0], _workbench.built_profile, "consumer receives an independent resource")
    assert_eq(source.snapshot(123), CaveWorkbench.preset(0, "ice").snapshot(123), "source resource stays intact")


func test_pending_edits_cannot_export_or_apply_a_stale_preview() -> void:
    _workbench.edit_definition(CaveWorkbench.preset(0), 123)
    await _finish_generation()
    _workbench._fields.chamber_width_m.value = 21
    watch_signals(_workbench)
    _workbench.select_definition()
    assert_signal_not_emitted(_workbench, "definition_selected")
    assert_eq(_workbench.save_definition("user://stargrot_test_stale.tres"), ERR_UNCONFIGURED)
    _workbench.generate()
    # A second request while the worker runs must produce the newest settings.
    _workbench._fields.chamber_width_m.value = 24
    _workbench.generate()
    await _finish_generation()
    assert_eq(_workbench.data.spec.chamber_width_m, 24.0)
    assert_false(_workbench._apply.disabled)


func test_saved_definition_roundtrips_seed_and_geometry_without_tool_nodes() -> void:
    var path := "user://stargrot_test_definition.tres"
    _workbench.edit_definition(CaveWorkbench.preset(0, "sand"), 876543)
    await _finish_generation()
    var original: PackedVector3Array = _workbench.data.faces
    assert_eq(_workbench.save_definition(path), OK)
    assert_eq(_workbench.load_definition(path), "")
    await _finish_generation()
    assert_eq(_workbench.built_seed, 876543)
    assert_eq(_workbench.data.faces, original)
    var text := FileAccess.get_file_as_string(path)
    assert_false(text.contains("cave_workbench"))
    assert_false(text.contains("stargrot_explorer"))
    DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_native_planet_consumes_exported_site_without_loading_the_workbench() -> void:
    var placement := Fixture.placement(Fixture.profile(0))
    var data := Fixture.data(placement)
    Fixture.fit(placement, data)
    var path := "user://stargrot_test_site.tres"
    assert_eq(ResourceSaver.save(placement, path), OK)
    var restored: CavePlacement = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
    data.cave_placements.append(restored)
    assert_eq(CavePlanetRegistry.prepare(data), "")
    assert_eq(data.stargrot_plans.size(), 1)
    assert_eq(data.stargrot_plans[0].cave.spec, placement.profile.snapshot(placement.seed))
    assert_false(FileAccess.get_file_as_string(path).contains("tools/stargrot"))
    DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
    var main_scene: String = ProjectSettings.get_setting("application/run/main_scene")
    assert_false(main_scene.contains("stargrot"), "normal game entry point preserved")
    var scene: PackedScene = load(main_scene)
    assert_false(scene.resource_path.contains("stargrot"), "UID resolves to normal game scene")
