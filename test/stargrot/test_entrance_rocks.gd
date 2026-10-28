extends Node3D
## Rendered regression: actual fitted porch and doline, deterministic decoration and shared colliders.

const Fixture := preload("res://test/unit/stargrot_fixture.gd")
var failures: Array[String] = []


func _ready() -> void:
    _run.call_deferred()


func check(value: bool, label: String) -> void:
    if not value:
        failures.append(label)
        push_error(label)


func _run() -> void:
    CaveNetwork.warm()
    var library := CaveAssetLibrary.default_for("rock", true)
    check(library.validation_error().is_empty(), "valid art library")
    var environment := WorldEnvironment.new()
    environment.environment = Environment.new()
    environment.environment.background_mode = Environment.BG_COLOR
    environment.environment.background_color = Color("738ca5")
    environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.environment.ambient_light_color = Color.WHITE
    environment.environment.ambient_light_energy = 1.0
    add_child(environment)
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-55, -35, 0)
    sun.light_intensity_lux = 18000.0
    sun.light_energy = 2.0
    add_child(sun)
    var camera := Camera3D.new()
    camera.current = true
    camera.attributes = CameraAttributesPractical.new()
    camera.attributes.exposure_multiplier = 1.3
    add_child(camera)
    var lamp := OmniLight3D.new()
    lamp.omni_range = 90.0
    lamp.light_intensity_lumens = 120000.0
    camera.add_child(lamp)
    for kind in ["ramp", "shaft"]:
        var profile := Fixture.profile(0)
        profile.entrance_type = kind
        profile.entrance_width_m = 16.0
        profile.entrance_height_m = 8.0
        profile.entrance_noise = 0.7
        profile.asset_library = library
        var site := Fixture.placement(profile, 4242)
        var planet := Fixture.data(site)
        var cave := Fixture.fit(site, planet)
        check(str(cave.error).is_empty(), kind + " fitted")
        var entry := CaveEntrance.build(planet, site, cave)
        var request := CavePreviewBuilder.decoration_request(library)
        var plan := CavePreviewBuilder.prepare_decorations(entry, request)
        check(plan == CavePreviewBuilder.prepare_decorations(entry, request), kind + " reproducible")
        var resident_tiles := CavePlanetRegistry.site_tiles(planet, site)
        var changed: Dictionary = entry.duplicate()
        changed.spec = entry.spec.duplicate()
        changed.spec.seed += 1
        check(plan != CavePreviewBuilder.prepare_decorations(changed, request), kind + " seed varies the dressing")
        for rule in library.decoration_rules():
            if rule.support.begins_with("entrance_"):
                check(CavePreviewBuilder.decoration_transforms(cave, rule).is_empty(), "no exterior art in underground rooms")
                for pose: Transform3D in plan.groups.get(rule.rule_name, []):
                    var box := pose * rule.mesh.get_aabb()
                    if rule.support == "entrance_ground":
                        for corner in 8:
                            var direction := (site.surface_transform() * box.get_endpoint(corner)).normalized()
                            check(resident_tiles.has(HEALPix.vec2pix_nest(planet.export_nside, direction)),
                                "exterior rock belongs to the loaded terrain footprint")
                    for section: Dictionary in entry.decor_sections:
                        for ring: PackedVector3Array in section.rings:
                            var walking: Vector3 = (ring[0] + ring[-1]) * 0.5 + Vector3.UP
                            check(not box.grow(0.8).has_point(walking), "walking capsule stays outside the rock")
                    if kind == "shaft":
                        var footprint := Rect2(Vector2(box.position.x, box.position.z), Vector2(box.size.x, box.size.z))
                        check(not footprint.grow(0.8).has_point(Vector2.ZERO), "central descent remains open")
        var total := 0
        for group: Array in plan.groups.values():
            total += group.size()
        check(total <= library.instance_budget, kind + " bounded")
        var used_meshes := {}
        var ground_count := 0
        var wall_count := 0
        for rule in library.entrance_library.decorations:
            var count: int = plan.groups.get(rule.rule_name, []).size()
            if count > 0:
                used_meshes[rule.mesh.resource_path] = true
            if rule.support == "entrance_ground":
                ground_count += count
            else:
                wall_count += count
        check(ground_count > 0 and wall_count > 0, kind + " dresses both exterior ground and walls")
        check(used_meshes.size() >= 6, kind + " uses at least six distinct exterior silhouettes")
        print("ENTRANCE ROCKS ", kind, " counts=", plan.groups.keys().map(func(key): return [key, plan.groups[key].size()]))
        entry.decoration_plan = plan
        var root := CavePreviewBuilder.instantiate(entry, library)
        add_child(root)
        for rule in library.entrance_library.decorations:
            var name: String = rule.rule_name
            if plan.groups.get(name, []).is_empty():
                continue
            var visual: MultiMeshInstance3D = root.get_node_or_null("Decor_" + name)
            var physical: StaticBody3D = root.get_node_or_null("DecorCollision_" + name)
            check(visual != null and physical != null, kind + " collidable outcrop")
            if visual and physical:
                for index in visual.multimesh.instance_count:
                    check(visual.multimesh.get_instance_transform(index).is_equal_approx(physical.get_child(index).transform),
                        kind + " collider follows visible buried rock")
        # The neutral ground is cut with the same real opening outlines as the native planet.
        var faces := PackedVector3Array()
        var frame := site.surface_transform()
        for x in range(-70, 70, 4):
            for z in range(-70, 110, 4):
                for p in [Vector3(x, 0, z), Vector3(x + 4, 0, z), Vector3(x + 4, 0, z + 4),
                        Vector3(x, 0, z), Vector3(x + 4, 0, z + 4), Vector3(x, 0, z + 4)]:
                    faces.append(frame * p)
        faces = CaveTerrainCut.collision_faces(faces, Vector3.ZERO, [site])
        var surface := CaveGenerator._empty_surface()
        var inverse := frame.affine_inverse()
        for index in range(0, faces.size(), 3):
            CaveGenerator._triangle(surface, inverse * faces[index], inverse * faces[index + 1],
                inverse * faces[index + 2], Vector3.UP * 100)
        var ground := CavePreviewBuilder.instantiate({"spec": {}, "wall": surface,
            "floor": CaveGenerator._empty_surface()}, null, true, false)
        var material := StandardMaterial3D.new()
        material.albedo_color = Color("766650")
        ground.get_node("CaveSurface").material_override = material
        root.add_child(ground)
        var inner := CavePreviewBuilder.instantiate(cave, library, true, false, site.network_origin())
        inner.position = site.network_origin()
        root.add_child(inner)
        camera.position = Vector3(14, 15, -15) if kind == "shaft" else Vector3(22, 13, -30)
        camera.look_at(Vector3(0, -6, 5) if kind == "shaft" else Vector3(0, 0, 14))
        for step in 12:
            await RenderingServer.frame_post_draw
        get_viewport().get_texture().get_image().save_png("res://.stargrot-validation/entrance-rocks-" + kind + ".png")
        if kind == "shaft":
            camera.position = Vector3(0, -2.0, 0)
            camera.look_at(Vector3(5, -6, 2))
            for step in 8:
                await RenderingServer.frame_post_draw
            get_viewport().get_texture().get_image().save_png("res://.stargrot-validation/entrance-rocks-wall.png")
        root.queue_free()
        await get_tree().process_frame
    # Contact sheet of the actual runtime meshes, without the burial hiding their silhouettes.
    var gallery := Node3D.new()
    add_child(gallery)
    var seen := {}
    for rule in library.entrance_library.decorations:
        if seen.has(rule.mesh.resource_path):
            continue
        var index := seen.size()
        seen[rule.mesh.resource_path] = true
        var instance := MeshInstance3D.new()
        instance.mesh = rule.mesh
        instance.material_override = rule.material
        instance.position = Vector3((index % 6) * 5.0, 0, (index / 6) * 5.0)
        gallery.add_child(instance)
    camera.position = Vector3(12, 16, 22)
    camera.look_at(Vector3(12, 0, 2.5))
    for step in 8:
        await RenderingServer.frame_post_draw
    get_viewport().get_texture().get_image().save_png("res://.stargrot-validation/exterior-rocks-library.png")
    print("STARGROT ENTRANCE ROCKS failures=", failures)
    get_tree().quit(0 if failures.is_empty() else 1)
