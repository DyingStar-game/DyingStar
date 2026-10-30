extends Node3D

const Fixture := preload("res://test/unit/stargrot_fixture.gd")
## Deterministic close-up independent of planet streaming and day/night.


func _ready() -> void:
    _run.call_deferred()


func _run() -> void:
    CaveNetwork.warm()
    var profile := Fixture.profile(0)
    profile.entrance_width_m = 10.0
    profile.entrance_height_m = 7.0
    profile.entrance_noise = 0.75
    var site := Fixture.placement(profile, 4242)
    var data := Fixture.data(site)
    var cave := Fixture.fit(site, data)
    if not str(cave.error).is_empty():
        push_error(cave.error)
        get_tree().quit(1)
        return
    var entry := CaveEntrance.build(data, site, cave)
    var library: CaveAssetLibrary = load("res://scenes/planet/cave/libraries/cave_rock_sculpted_open.tres")
    var inner := CavePreviewBuilder.instantiate(cave, library, true, false, site.network_origin())
    inner.position = site.network_origin()
    add_child(inner)
    add_child(CavePreviewBuilder.instantiate(entry, library, true, false))
    var frame := site.surface_transform()
    var terrain := PackedVector3Array()
    for x in range(-80, 80, 4):
        for z in range(-40, 120, 4):
            for p in [Vector3(x, 0, z), Vector3(x + 4, 0, z), Vector3(x + 4, 0, z + 4),
                    Vector3(x, 0, z), Vector3(x + 4, 0, z + 4), Vector3(x, 0, z + 4)]:
                terrain.append(frame * p)
    var cut := CaveTerrainCut.collision_faces(terrain, Vector3.ZERO, [site])
    var ground := CaveGenerator._empty_surface()
    var inverse := frame.affine_inverse()
    for index in range(0, cut.size(), 3):
        CaveGenerator._triangle(ground, inverse * cut[index], inverse * cut[index + 1], inverse * cut[index + 2], Vector3(0, 100, 0))
    var terrain_data := {"spec": {}, "wall": ground, "floor": CaveGenerator._empty_surface()}
    var ground_node := CavePreviewBuilder.instantiate(terrain_data, null, true, false)
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.28, 0.32, 0.34)
    (ground_node.get_node("CaveSurface") as MeshInstance3D).material_override = material
    add_child(ground_node)
    var environment := WorldEnvironment.new()
    environment.environment = Environment.new()
    environment.environment.background_mode = Environment.BG_COLOR
    environment.environment.background_color = Color(0.25, 0.4, 0.55)
    environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.environment.ambient_light_color = Color.WHITE
    environment.environment.ambient_light_energy = 0.7
    add_child(environment)
    var light := DirectionalLight3D.new()
    light.rotation_degrees = Vector3(-45, -25, 0)
    add_child(light)
    var camera := Camera3D.new()
    camera.fov = 75
    camera.near = 0.05
    add_child(camera)
    camera.make_current()
    var lamp := OmniLight3D.new()
    lamp.light_energy = 3.0
    lamp.omni_range = 35.0
    camera.add_child(lamp)
    var porch := CavePortal.build_porch(data, site, site.openings()[0])
    var rings: Array = porch.rings
    var rim: PackedVector3Array = rings[0]
    var middle := (rim[0] + rim[-1]) * 0.5
    var axes := CavePortal.porch_axes(site.portal_descent_deg)
    camera.position = middle - axes.forward * 10.0 + Vector3.UP * 3.0
    camera.look_at(middle + axes.up * 3.0)
    await _capture("seams-mouth")
    var ring: PackedVector3Array = rings[rings.size() / 2]
    middle = (ring[0] + ring[-1]) * 0.5
    camera.position = middle + Vector3.UP * 1.7
    camera.look_at(site.network_origin() + Vector3(0, 3, 24))
    await _capture("seams-interior")
    print("STARGROT SEAMS VISUAL complete")
    get_tree().quit()


func _capture(label: String) -> void:
    for frame in 8:
        await RenderingServer.frame_post_draw
    get_viewport().get_texture().get_image().save_png("res://.stargrot-validation/" + label + ".png")
