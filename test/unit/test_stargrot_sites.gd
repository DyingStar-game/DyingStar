extends GutTest

const Fixture := preload("res://test/unit/stargrot_fixture.gd")


## A site [param index] × 0.02° east, fitted to flat ground when [param fitted].
func _site(index: int, fitted: bool = true) -> CavePlacement:
    var site := Fixture.placement(Fixture.profile(0))
    site.placement_id = "test-site-%d" % index
    site.longitude_deg = index * 0.02
    site.resource_name = "Grotte %d" % index
    if fitted:
        Fixture.fit(site, Fixture.data(site))
    return site


## First open point above a chamber's floor, in the cave's own frame.
func _open_point(cave: Dictionary, room: Dictionary) -> Vector3:
    var height := -6.0
    while height < float(room.size.y):
        var point: Vector3 = room.a + Vector3.UP * height
        if float(cave.sampler.call("Sample", point)) > 0.5:
            return point
        height += 0.25
    return room.a


func test_collection_add_edit_delete_and_last_delete_survive_reload() -> void:
    var collection := CaveSiteCollection.new()
    collection.put(_site(1, false))
    collection.put(_site(2, false))
    assert_eq(collection.sites.size(), 2)
    assert_eq(collection.selected_id, "test-site-2")
    var edited := _site(2, false)
    edited.seed = 987
    collection.put(edited)
    assert_eq(collection.sites.size(), 2)
    assert_eq(collection.selected().seed, 987)
    var path := "user://stargrot_unit_sites.tres"
    assert_eq(collection.save_to(path), OK)
    collection.remove_selected()
    assert_eq(collection.selected_id, "test-site-1")
    assert_eq(collection.save_to(path), OK, "replace saved collection atomically")
    var restored: CaveSiteCollection = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
    assert_eq(restored.sites.size(), 1)
    assert_eq(restored.selected_id, "test-site-1")
    collection.remove_selected()
    assert_null(collection.selected())
    assert_eq(collection.save_to(path), OK)
    restored = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
    assert_true(restored.sites.is_empty(), "empty save does not resurrect the initial cave")
    assert_eq(restored.selected_id, "")
    DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_invalid_collection_cannot_overwrite_last_good_save() -> void:
    var collection := CaveSiteCollection.new()
    collection.put(_site(1, false))
    var path := "user://stargrot_unit_sites_invalid.tres"
    assert_eq(collection.save_to(path), OK)
    var previous := FileAccess.get_file_as_string(path)
    collection.sites.append(_site(1, false))
    assert_false(collection.validation_error().is_empty())
    assert_eq(collection.save_to(path), ERR_INVALID_DATA)
    assert_eq(FileAccess.get_file_as_string(path), previous)
    DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_native_registry_prepares_two_separate_sites_and_removes_deleted_geometry() -> void:
    var collection := CaveSiteCollection.new()
    collection.put(_site(1))
    collection.put(_site(2))
    var data := Fixture.data(collection.selected())
    data.cave_placements = collection.on_body(data.planet_name)
    assert_eq(CavePlanetRegistry.prepare(data), "")
    assert_eq(data.stargrot_plans.size(), 2)
    var plan: Dictionary = data.stargrot_plans[1]
    var deleted_point: Vector3 = collection.selected().cave_transform() * _open_point(plan.cave, plan.cave.graph.rooms[0])
    assert_true(CavePlanetRegistry.contains(data, deleted_point))
    var signature := data.stargrot_signature()
    collection.remove_selected()
    data.cave_placements = collection.on_body(data.planet_name)
    assert_eq(CavePlanetRegistry.prepare(data), "")
    assert_eq(data.stargrot_plans.size(), 1)
    assert_false(CavePlanetRegistry.contains(data, deleted_point))
    assert_ne(data.stargrot_signature(), signature, "removal rekeys terrain holes/collisions")
    assert_true(collection.on_body("tarsis_3_1").is_empty())


func test_overlapping_sites_and_trial_capacity_are_rejected() -> void:
    var first := _site(1)
    var second := _site(1)
    second.placement_id = "test-site-twin"
    var data := Fixture.data(first)
    data.cave_placements = [first, second]
    assert_true(CavePlanetRegistry.prepare(data).contains("proche"))
    assert_true(data.stargrot_plans.is_empty())
    data.cave_placements.clear()
    for index in CavePlanetRegistry.MAX_TRIAL_SITES + 1:
        data.cave_placements.append(_site(index, false))
    assert_true(CavePlanetRegistry.prepare(data).contains("512 sites"))
    assert_true(data.stargrot_plans.is_empty())
