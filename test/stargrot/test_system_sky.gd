extends Node

var explorer
var checks: int = 0
var failures: Array[String] = []


func check(condition: bool, label: String) -> void:
    checks += 1
    if not condition:
        failures.append(label)
        push_error(label)


func _ready() -> void:
    preload("res://test/stargrot/test_cache.gd").use_directory("StarGrotteSkyTests")
    var collection := CaveSiteCollection.new()
    collection.put(load("res://levels/stargrot/initial_cave.tres").duplicate(true))
    collection.save_to("user://stargrot_test_sky_sites.tres")
    explorer = load("res://levels/stargrot/stargrot_explorer.tscn").instantiate()
    explorer.placement_path = "user://stargrot_test_sky_missing.tres"
    explorer.collection_path = "user://stargrot_test_sky_sites.tres"
    DirAccess.remove_absolute(ProjectSettings.globalize_path(explorer.placement_path))
    add_child(explorer)
    _run.call_deferred()


func _hour(value: float) -> void:
    for i in 5:
        var current: float = explorer.body.get_local_solar_time(explorer.player.global_position)
        explorer._shift_time(wrapf(value - current, -12.0, 12.0))
    await get_tree().create_timer(2.0).timeout


func _capture(filename: String) -> void:
    if DisplayServer.get_name() == "headless":
        return
    await RenderingServer.frame_post_draw
    get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../" + filename))


func _run() -> void:
    await get_tree().create_timer(20.0).timeout
    explorer.player.god_mode = true
    check(explorer._system_bodies.size() == 19, "all 19 native bodies present together")
    check(explorer._system_bodies.tarsis_3_1.get_parent() == explorer.body, "native moon hierarchy retained")
    var moon: Planet = explorer._system_bodies.tarsis_3_1
    check(absf(moon.global_position.distance_to(explorer.body.global_position)
        - moon.orbit_offset_at(Globals.sim_time()).length()) < 100.0, "moon keeps native orbital distance")
    check(explorer._sun.get_star() != null, "native sun resolves system star")
    check(explorer.player.get_node("AtmosphereRenderer").current_profile() != null, "native atmosphere profile active")
    check(explorer.player.camera.far >= 1.0e13, "camera includes distant system bodies")
    var local_before: Vector3 = explorer.player.position
    await _hour(12.0)
    var noon: float = explorer._sun.light_energy if explorer._sun.visible else 0.0
    var noon_dir: Vector3 = explorer._sun.star_direction
    await _capture("stargrot-systeme-jour.png")
    await _hour(0.0)
    var midnight: float = explorer._sun.light_energy if explorer._sun.visible else 0.0
    check(noon > midnight + 0.1, "native direct light changes from day to night")
    check(noon_dir.dot(explorer._sun.star_direction) < 0.0, "native star direction follows planet rotation")
    var moved: float = explorer.player.position.distance_to(local_before)
    check(moved < 0.05, "clock changes retain player local position (moved %.3f m)" % moved)
    check(explorer.body.global_basis.is_equal_approx(Basis.IDENTITY), "local collision frame stays stable")
    var terrain: PlanetTerrain = explorer.body.planet_terrain
    var lighting_updated := false
    for entry: Dictionary in terrain._active_chunks.values():
        var mesh: MeshInstance3D = entry.get("mesh_instance")
        if is_instance_valid(mesh):
            var direction: Vector3 = mesh.get_instance_shader_parameter("star_dir_world")
            lighting_updated = direction.dot(terrain._compute_star_dir()) > 0.9999
            break
    check(lighting_updated, "existing terrain meshes follow updated star direction")
    await _capture("stargrot-systeme-nuit.png")
    explorer._workbench.hide()
    explorer._orbit_view()
    await get_tree().create_timer(8.0).timeout
    await _capture("stargrot-systeme-orbite.png")
    var old_ids := []
    for planet in explorer._system_bodies.values():
        old_ids.append(planet.get_instance_id())
    await explorer._load_body("tarsis_3_1")
    await get_tree().create_timer(8.0).timeout
    check(explorer._system_bodies.size() == 19, "body selection keeps full system loaded")
    check(old_ids.has(explorer.body.get_instance_id()), "body selection reuses the existing moon")
    check(explorer.player.get_node("AtmosphereRenderer").current_body() == explorer.body, "sky follows selected moon")
    await _capture("stargrot-systeme-lune.png")
    var primary: Planet = explorer._system_bodies.tarsis_3
    var star_direction := primary.global_position.direction_to(explorer._universe.get_node("Star").global_position)
    print("STARGROT DISTANT primary_chunks=", primary.planet_terrain.active_chunk_count(), " star_phase=",
        star_direction.dot(primary.global_position.direction_to(explorer.player.global_position)))
    explorer.player.look_at(primary.global_position, Vector3.UP)
    explorer.player.camera_pivot.rotation = Vector3.ZERO
    explorer._markers.visible = false
    explorer._markers._clear()
    await get_tree().create_timer(3.0).timeout
    await _capture("stargrot-systeme-planete-depuis-lune.png")
    if DisplayServer.get_name() != "headless":
        var image := get_viewport().get_texture().get_image()
        var center := image.get_size() / 2
        var lit_pixels := 0
        for y in range(center.y - 20, center.y + 20):
            for x in range(center.x - 20, center.x + 20):
                var color := image.get_pixel(x, y)
                if maxf(color.r, maxf(color.g, color.b)) > 0.08:
                    lit_pixels += 1
        check(lit_pixels > 100, "distant corundum planet is visibly rendered without markers")
    var file := FileAccess.open("res://test/stargrot/system-sky-results.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"checks": checks, "failures": failures, "noon_energy": noon, "midnight_energy": midnight}, "  "))
    file.close()
    print("STARGROT SYSTEM SKY ", checks, " checks; failures=", failures)
    await explorer.shutdown()
    explorer.free()
    get_tree().quit(0 if failures.is_empty() else 1)
