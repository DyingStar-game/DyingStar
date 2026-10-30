extends Node3D
## Native-renderer acceptance and captures of the art pilot in a generated version 8 cave.

var _camera: Camera3D
var _cave: Node3D
var _room: Dictionary


func _ready() -> void:
    _run.call_deferred()


func _run() -> void:
    CaveNetwork.warm()
    var library: CaveAssetLibrary = load("res://scenes/planet/cave/libraries/cave_rock_sculpted.tres")
    var profile := CaveWorkbench.preset(1, "rock", library)
    profile.chamber_count = 5
    profile.level_count = 1
    profile.depth_m = 0
    profile.chamber_width_m = 40
    profile.chamber_height_m = 18
    profile.network_style = "ramiform"
    print("STARGROT ROCK CAPTURE building seeded v8 cave")
    var data := CaveGenerator.build(profile.snapshot(7654321))
    print("STARGROT ROCK CAPTURE geometry ready")
    if not str(data.error).is_empty():
        push_error(str(data.error))
        get_tree().quit(1)
        return
    var request := CavePreviewBuilder.decoration_request(library)
    var prepared: Array = [{}]
    var started := Time.get_ticks_msec()
    var task := WorkerThreadPool.add_task(func(): prepared[0] = CavePreviewBuilder.prepare_decorations(data, request))
    while not WorkerThreadPool.is_task_completed(task):
        await get_tree().process_frame
    WorkerThreadPool.wait_for_task_completion(task)
    data["decoration_plan"] = prepared[0]
    print("STARGROT DRESSING WORKER ms=", Time.get_ticks_msec() - started)
    _cave = CavePreviewBuilder.instantiate(data, library, true, true)
    add_child(_cave)
    _room = data.graph.rooms[0]
    for room: Dictionary in data.graph.rooms:
        if float(room.size.x) * float(room.size.z) > float(_room.size.x) * float(_room.size.z):
            _room = room
    var environment := WorldEnvironment.new()
    environment.environment = Environment.new()
    environment.environment.background_mode = Environment.BG_COLOR
    environment.environment.background_color = Color("18262b")
    environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.environment.ambient_light_color = Color("a7bbca")
    environment.environment.ambient_light_energy = 0.5
    environment.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
    add_child(environment)
    _light(_room.a + Vector3(0, 6, 0), Color("ffe3b6"), 3.5, 50)
    _light(_room.a + Vector3(-8, 3, -4), Color("a2cee0"), 2, 40)
    _camera = Camera3D.new()
    _camera.current = true
    _camera.fov = 75
    _camera.far = 3000
    add_child(_camera)
    _camera.position = _room.a + Vector3(-1, 2.1, 3)
    _camera.look_at(_room.a + Vector3(float(_room.size.x) * 0.7, 1.8, 0))
    var counts := {}
    var transforms_match := true
    var boxes: Array[AABB] = []
    for child in _cave.get_children():
        if child is MultiMeshInstance3D:
            counts[str(child.name)] = child.multimesh.instance_count
            var collision: StaticBody3D = _cave.get_node_or_null(str(child.name).replace("Decor_", "DecorCollision_"))
            for index in child.multimesh.instance_count:
                var drawn: Transform3D = child.multimesh.get_instance_transform(index)
                if collision:
                    var physical: Transform3D = collision.get_child(index).transform
                    transforms_match = transforms_match and physical.origin.distance_to(drawn.origin) < 0.001
                    for axis in 3:
                        transforms_match = transforms_match and physical.basis[axis].distance_to(drawn.basis[axis]) < 0.00001
                var box: AABB = drawn * child.multimesh.mesh.get_aabb()
                for other in boxes:
                    transforms_match = transforms_match and not box.intersects(other)
                boxes.append(box)
    for step in 12:
        await get_tree().process_frame
    await RenderingServer.frame_post_draw
    get_viewport().get_texture().get_image().save_png("res://../stargrot-roches-en-grotte.png")
    # A second angle frames an actual resident boulder and its surrounding floor.
    var boulder: MultiMeshInstance3D = _cave.get_node_or_null("Decor_rock_boulder_01")
    if boulder and boulder.multimesh.instance_count > 0:
        var point := boulder.multimesh.get_instance_transform(0).origin
        var toward: Vector3 = (_room.a - point).normalized()
        _camera.position = point + toward * 4.5 + Vector3.UP * 2.0
        _camera.look_at(point + Vector3.UP * 0.5)
        _light(point + toward * 2 + Vector3.UP * 4, Color("ffdfb5"), 2, 15)
        await RenderingServer.frame_post_draw
        await RenderingServer.frame_post_draw
        get_viewport().get_texture().get_image().save_png("res://../stargrot-roches-detail-jeu.png")
    var passed := not counts.is_empty() and library.validation_error().is_empty() and transforms_match
    var file := FileAccess.open("res://test/stargrot/rock-assets-results.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"passed": passed, "instances": counts,
        "poses_and_separation": transforms_match, "generator": data.spec.version}, "  "))
    file.close()
    print("STARGROT ROCK ASSETS NATIVE passed=", passed, " instances=", counts)
    get_tree().quit(0 if passed else 1)


func _light(point: Vector3, color: Color, energy: float, distance: float) -> void:
    var light := OmniLight3D.new()
    light.position = point
    light.light_color = color
    light.light_energy = energy
    light.omni_range = distance
    light.shadow_enabled = true
    add_child(light)
