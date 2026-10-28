extends GutTest

class SlopedData extends PlanetData:
    var frame: Transform3D

    func crack_aware_surface_dist(direction: Vector3, _nside: int = -1, _spacing: float = 0.0) -> float:
        var point := frame.affine_inverse() * (direction * radius)
        return radius + point.z * 0.3


func test_coordinate_pick_respects_native_longitude_and_poles() -> void:
    for lonlat in [Vector2(39, 24), Vector2(-179.9, -70), Vector2(0, 89.9)]:
        var point := CaveTerrain.lonlat_to_dir(lonlat) * 6356000.0
        assert_lt(CaveSurfacePicker.coordinates(point).distance_to(lonlat), 0.000001)


func test_picker_ignores_props_caves_and_other_planets() -> void:
    var terrain := Node3D.new()
    add_child_autofree(terrain)
    var ground := StaticBody3D.new()
    terrain.add_child(ground)
    var cave := Node3D.new()
    terrain.add_child(cave)
    var wall := StaticBody3D.new()
    cave.add_child(wall)
    assert_true(CaveSurfacePicker.is_terrain_hit(ground, terrain))
    assert_false(CaveSurfacePicker.is_terrain_hit(wall, terrain))
    assert_false(CaveSurfacePicker.is_terrain_hit(ground, cave))
    var picker := CaveSurfacePicker.new()
    add_child_autofree(picker)
    watch_signals(picker)
    picker.begin(CaveWorkbench.preset(0), 42, 178)
    var event := InputEventMouseButton.new()
    event.button_index = MOUSE_BUTTON_WHEEL_UP
    event.pressed = true
    assert_true(picker.handle_input(event))
    assert_almost_eq(picker.heading, -177.0, 0.0001)
    event.button_index = MOUSE_BUTTON_LEFT
    picker.handle_input(event)
    assert_signal_not_emitted(picker, "accepted", "empty sky cannot add a site")
    event.button_index = MOUSE_BUTTON_RIGHT
    picker.handle_input(event)
    assert_false(picker.active)
    assert_signal_emitted(picker, "cancelled")


func test_topography_heading_is_independent_of_draft_rotation() -> void:
    var site := CavePlacement.new()
    site.longitude_deg = 0
    site.latitude_deg = 0
    var data := SlopedData.new()
    data.radius = site.planet_radius_m
    data.frame = site.surface_transform()
    var first := CavePopulation.topography(data, site)
    site.heading_deg = 126
    var second := CavePopulation.topography(data, site)
    assert_almost_eq(float(first.heading), float(second.heading), 0.00001)
    assert_almost_eq(float(first.slope), 0.3, 0.001)
    assert_eq(site.heading_deg, 126.0, "survey does not mutate the draft")


func test_biome_and_relief_choose_plausible_entries() -> void:
    assert_eq(CavePopulation.entrance_for("basalt", 0.01), "shaft")
    assert_eq(CavePopulation.entrance_for("rock", 0.5), "ramp")
    assert_true(CavePopulation.excluded_biome("active_lava"))
    assert_true(CavePopulation.excluded_biome("ocean"))
    assert_false(CavePopulation.excluded_biome("basalt_lava_field"))


func test_exit_rims_are_convex_and_curved() -> void:
    var profile := CaveWorkbench.preset(0)
    profile.exit_open = true
    for width in [3.0, 12.0]:
        profile.exit_width_m = width
        for seed_value in [0, 42, 123, 2147483647]:
            var rim := CaveNaturalOpening.outline(profile.snapshot(seed_value))
            assert_gt(rim.size(), 40)
            var perimeter := 0.0
            var longest := 0.0
            for index in rim.size():
                var edge := rim[index].distance_to(rim[(index + 1) % rim.size()])
                perimeter += edge
                longest = maxf(longest, edge)
            assert_lt(longest / perimeter, 0.08, "no long straight trench edges")
            var hull := Geometry2D.convex_hull(rim)
            assert_eq(hull.size(), rim.size() + 1, "exact convex clip contract")


func test_cursor_ray_accepts_loaded_surface_and_emits_body_fixed_point() -> void:
    var planet := Node3D.new()
    add_child_autofree(planet)
    planet.position = Vector3(100, -1000, 30)
    var terrain := Node3D.new()
    planet.add_child(terrain)
    var ground := StaticBody3D.new()
    ground.position.y = 1000
    terrain.add_child(ground)
    var shape := CollisionShape3D.new()
    var box := BoxShape3D.new()
    box.size = Vector3(200, 1, 200)
    shape.shape = box
    ground.add_child(shape)
    var camera := Camera3D.new()
    planet.add_child(camera)
    camera.position = Vector3(0, 1040, 30)
    camera.look_at(planet.to_global(Vector3(0, 1000, 0)))
    var picker := CaveSurfacePicker.new()
    add_child_autofree(picker)
    watch_signals(picker)
    picker.begin(CaveWorkbench.preset(0), 42, 0)
    await get_tree().physics_frame
    await get_tree().physics_frame
    picker.update_cursor(camera, planet, terrain, camera.get_viewport().get_visible_rect().size * 0.5)
    assert_true(picker.valid, "a real physics ray finds loaded terrain")
    assert_almost_eq(picker._point.y, 1000.5, 0.001, "point stays in body frame after rebasing")
    var event := InputEventMouseButton.new()
    event.button_index = MOUSE_BUTTON_LEFT
    event.pressed = true
    picker.handle_input(event)
    assert_signal_emitted(picker, "accepted")
    assert_false(picker.active, "one click publishes only one request")
