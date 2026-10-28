extends GutTest
## Imported art must keep support pivots, bounded meshes, and identical client/server decoration poses.

const LIBRARY := "res://scenes/planet/cave/libraries/cave_rock_sculpted.tres"


func before_all() -> void:
    CaveNetwork.warm()


func test_imported_pilot_has_shared_colour_material_and_grounded_meshes() -> void:
    for path in [LIBRARY, "res://scenes/planet/cave/libraries/cave_rock_sculpted_open.tres"]:
        var library: CaveAssetLibrary = load(path)
        assert_eq(library.validation_error(), "", path)
        assert_eq(library.decorations.size(), 6, "interior art remains independent")
        for rule in library.decorations:
            var box := rule.mesh.get_aabb()
            assert_almost_eq(box.position.y, 0.0, 0.001, rule.rule_name + " support pivot")
            assert_gt(box.size.y, 0.2)
            var arrays := rule.mesh.surface_get_arrays(0)
            assert_gt(arrays[Mesh.ARRAY_COLOR].size(), 0, "vertex tints survived glTF import")
            assert_lte(arrays[Mesh.ARRAY_INDEX].size() / 3, 3000, "pilot triangle budget")
            assert_true(rule.material == library.decorations[0].material, "one shared material")
            assert_eq(rule.collision_shape != null, rule.mesh.resource_path.get_file().begins_with("rock_boulder"))


func test_exterior_library_has_distinct_meshes_and_can_be_replaced_independently() -> void:
    var interior: CaveAssetLibrary = load(LIBRARY)
    var exterior := interior.entrance_library
    assert_not_null(exterior)
    assert_eq(exterior.validation_error(), "")
    var meshes := {}
    var geometry := {}
    for rule in exterior.decorations:
        assert_true(rule.support in ["entrance_ground", "entrance_wall"])
        assert_not_null(rule.collision_shape)
        assert_true(rule.mesh.resource_path.contains("/rock_exterior/"))
        for inside in interior.decorations:
            assert_ne(rule.mesh.resource_path, inside.mesh.resource_path, "exterior never reuses an interior mesh")
        meshes[rule.mesh.resource_path] = true
        geometry[str(rule.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]).sha256_text()] = true
    assert_eq(meshes.size(), 12, "twelve original meshes")
    assert_eq(geometry.size(), 12, "different geometry, not copies of the same mesh")
    var custom: CaveAssetLibrary = interior.duplicate()
    custom.entrance_library = null
    assert_eq(custom.decoration_rules().size(), 6, "exterior art can be detached without changing interiors")
    assert_eq(interior.decoration_rules().size(), 30)


func test_resident_physics_uses_the_same_bounded_transforms_as_visuals() -> void:
    var library: CaveAssetLibrary = load(LIBRARY)
    var profile := CaveWorkbench.preset(1, "rock", library)
    var cave := CaveGenerator.build(profile.snapshot(7654321))
    assert_eq(str(cave.error), "")
    var client := CavePreviewBuilder.instantiate(cave, library, true, false)
    var server := CavePreviewBuilder.instantiate(cave, library, false, true)
    var visual_count := 0
    var collider_count := 0
    for rule in library.decorations:
        var visual: MultiMeshInstance3D = client.get_node_or_null("Decor_" + rule.rule_name)
        var body: StaticBody3D = server.get_node_or_null("DecorCollision_" + rule.rule_name)
        assert_null(client.get_node_or_null("DecorCollision_" + rule.rule_name))
        assert_null(server.get_node_or_null("Decor_" + rule.rule_name))
        if visual:
            visual_count += visual.multimesh.instance_count
            if rule.collision_shape:
                assert_not_null(body)
                if body:
                    assert_eq(body.get_child_count(), visual.multimesh.instance_count)
                    for index in body.get_child_count():
                        var shape: CollisionShape3D = body.get_child(index)
                        # The Dummy renderer returns identity for GPU transform reads. The graphical
                        # acceptance scene checks these poses against real MultiMesh readback.
                        if DisplayServer.get_name() != "headless":
                            var drawn := visual.multimesh.get_instance_transform(index)
                            assert_lt(shape.position.distance_to(drawn.origin), 0.001, "poses agree within 1 mm")
                            for axis in 3:
                                assert_lt(shape.basis[axis].distance_to(drawn.basis[axis]), 0.00001)
                        assert_true(shape.shape == rule.collision_shape, "shared convex shape")
                        collider_count += 1
            else:
                assert_null(body, "rubble and fine formations remain visual")
    assert_gt(visual_count, 0, "the v8 rooms actually receive this library")
    assert_gt(collider_count, 0, "some boulders are present")
    assert_lte(visual_count, library.instance_budget)
    client.free()
    server.free()


func test_boulder_collider_answers_real_physics_rays() -> void:
    var library: CaveAssetLibrary = load(LIBRARY)
    var body := StaticBody3D.new()
    var shape := CollisionShape3D.new()
    shape.shape = library.decorations[0].collision_shape
    body.add_child(shape)
    add_child_autofree(body)
    body.position = Vector3(10000, 10000, 10000)
    await get_tree().physics_frame
    await get_tree().physics_frame
    var query := PhysicsRayQueryParameters3D.create(body.position + Vector3.UP * 4,
        body.position + Vector3.DOWN, body.collision_layer)
    var hit := body.get_world_3d().direct_space_state.intersect_ray(query)
    assert_false(hit.is_empty(), "the imported convex hull blocks a physical ray")
    if not hit.is_empty():
        assert_true(hit.collider == body)
