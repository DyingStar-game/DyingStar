extends Node
## End-to-end on Tarsis: a porch on a real mountain flank, a doline on flat ground and a version 9 cave whose
## light shafts open the plain, placed through the explorer's shared fitter, streamed in, then crossed by
## physics rays. Captures go to .stargrot-validation/.

var failures: Array[String] = []
var checks: int = 0
var explorer


func _mouth_library() -> CaveAssetLibrary:
    var path := "res://scenes/planet/cave/libraries/cave_rock_open.tres"
    if "--stargrot-styled-assets" in OS.get_cmdline_user_args():
        path = "res://scenes/planet/cave/libraries/cave_rock_sculpted_open.tres"
    return load(path)


func _ready() -> void:
    preload("res://test/stargrot/test_cache.gd").use_directory("StarGrottePortalTests")
    _run.call_deferred()


func check(ok: bool, label: String) -> void:
    checks += 1
    if not ok:
        failures.append(label)
        push_error(label)


func _run() -> void:
    var path := "user://portal_sites.tres"
    CaveSiteCollection.new().save_to(path)
    explorer = load("res://levels/stargrot/stargrot_explorer.tscn").instantiate()
    explorer.collection_path = path
    add_child(explorer)
    await get_tree().create_timer(1.0).timeout
    await _check_clock_keys()
    var data: PlanetData = explorer.body.planet_data
    var steep := await _find_site(data, CavePopulation.mountain_candidates(data), 0.35, INF)
    check(steep.x < INF, "a steep mountain flank exists among the mountain outlines")
    if steep.x < INF:
        await _porch(steep)
    if "--stargrot-porch-only" in OS.get_cmdline_user_args():
        await explorer.shutdown()
        explorer.free()
        print("STARGROT PORCH REVIEW failures=", failures)
        get_tree().quit(0 if failures.is_empty() else 1)
        return
    var reference: CavePlacement = load("res://levels/stargrot/initial_cave.tres")
    var flats: Array[Vector2] = []
    for step in 24:
        flats.append(reference.geographic_lonlat() + Vector2(cos(step * 0.7), sin(step * 0.7)) * 0.02 * (1 + step / 6))
    var flat := await _find_site(data, flats, 0.0, 0.05)
    check(flat.x < INF, "a flat site exists near the reference cave")
    if flat.x < INF:
        await _doline(flat)
    var plain := await _find_site(data, flats.slice(8), 0.0, 0.08)
    check(plain.x < INF, "a second plain exists for the light shafts")
    if plain.x < INF:
        await _lights(plain)
    await explorer.shutdown()
    explorer.free()
    var file := FileAccess.open("res://test/stargrot/portal-planet-results.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"checks": checks, "failures": failures}, "  "))
    file.close()
    print("STARGROT PORTAL PLANET ", checks, " checks; failures=", failures)
    get_tree().quit(0 if failures.is_empty() else 1)


## The base game's + / - clock keys move the sky in the atelier too, one hour per press, and back.
func _check_clock_keys() -> void:
    var before := Globals.debug_time_offset
    for key in [KEY_KP_ADD, KEY_KP_SUBTRACT]:
        var press := InputEventKey.new()
        press.pressed = true
        press.physical_keycode = key
        explorer._unhandled_input(press)
        var expected := before + (Globals.DEBUG_TIME_STEP if key == KEY_KP_ADD else 0.0)
        check(is_equal_approx(Globals.debug_time_offset, expected), "clock key %d moves the sky an hour" % key)
    await get_tree().physics_frame
    check("Soleil" in explorer._status.text, "the HUD shows the sun's height")


## First candidate whose 80 m slope lies in [low, high), its tiles loaded first.
func _find_site(data: PlanetData, candidates: Array[Vector2], low: float, high: float) -> Vector2:
    for lonlat in candidates.slice(0, 60):
        var probe := CavePlacement.new()
        probe.format_version = 2
        probe.longitude_deg = lonlat.x
        probe.latitude_deg = lonlat.y
        probe.planet_radius_m = data.radius
        probe.profile = CaveWorkbench.preset(0)
        var tiles := {}
        CavePlanetRegistry._collect_tiles(data, probe.surface_transform(), -80, 80, 80, tiles)
        var deadline := Time.get_ticks_msec() + 15000
        while not CavePlanetRegistry.request_tiles(data, tiles) and Time.get_ticks_msec() < deadline:
            await get_tree().create_timer(0.05).timeout
        probe.surface_height_m = data.crack_aware_surface_dist(probe.surface_direction(), data.export_nside) - data.radius
        var relief := CavePopulation.topography(data, probe)
        if low <= 0.0:
            if float(relief.slope) < high:
                print("PORTAL SITE ", lonlat, " slope=", relief.slope)
                return lonlat
            continue
        # A wall face, not a plateau's lip: walk along the fall line, down to a cliff's foot or up a flank, until
        # the relief rises right in front of the mouth.
        probe.heading_deg = relief.heading
        tiles.clear()
        CavePlanetRegistry._collect_tiles(data, probe.surface_transform(), -170, 170, 40, tiles)
        deadline = Time.get_ticks_msec() + 15000
        while not CavePlanetRegistry.request_tiles(data, tiles) and Time.get_ticks_msec() < deadline:
            await get_tree().create_timer(0.05).timeout
        for climb in range(-150, 151, 10):
            var point := probe.surface_transform() * Vector3(0.0, 0.0, climb)
            var site := probe.duplicate(true)
            var at := CaveSurfacePicker.coordinates(point)
            site.longitude_deg = at.x
            site.latitude_deg = at.y
            site.heading_deg = 0.0
            site.surface_height_m = data.crack_aware_surface_dist(site.surface_direction(), data.export_nside) - data.radius
            var local := CavePopulation.topography(data, site)
            site.heading_deg = local.heading
            if float(local.slope) >= low and CaveEntrance.ground_point(data, site, 0.0, 12.0).y >= 6.0:
                print("PORTAL SITE ", at, " slope=", local.slope, " climb=", climb)
                return at
    return Vector2(INF, INF)


func _place(lonlat: Vector2, profile: CaveProfile, cave_seed: int) -> CavePlacement:
    explorer._select_definition(profile, cave_seed)
    explorer._longitude.value = lonlat.x
    explorer._latitude.value = lonlat.y
    explorer._heading.value = 0
    var before: int = explorer.collection.sites.size()
    explorer._place_here(true)
    var deadline := Time.get_ticks_msec() + 240000
    while explorer._busy and Time.get_ticks_msec() < deadline:
        await get_tree().create_timer(0.1).timeout
    check(explorer.collection.sites.size() == before + 1, "placed: " + explorer._hint.text)
    print("PORTAL PLACEMENT COMPLETE saved=", explorer.collection.sites.size() == before + 1)
    if explorer.collection.sites.size() == before + 1:
        return explorer.collection.sites.back()
    return null


## Diagnostic for a refused porch: the fitted values and the bend's clearance under the relief.
func _explain(lonlat: Vector2, profile: CaveProfile, cave_seed: int) -> void:
    var data: PlanetData = explorer.body.planet_data
    var site := CavePlacement.new()
    site.format_version = 2
    site.placement_id = "explain"
    site.planet_name = explorer.selected_key
    site.longitude_deg = lonlat.x
    site.latitude_deg = lonlat.y
    site.profile = profile.duplicate(true)
    site.seed = cave_seed
    site.cover_m = maxf(2.0, profile.chamber_height_m * 0.15)
    site.ramp_length_m = 20.0
    site.planet_radius_m = data.radius
    site.terrain_version = data.chunk_data_version
    var prepared: Dictionary = await explorer._population.prepare_site(data, site)
    print("EXPLAIN error=", prepared.error, " heading=", site.heading_deg, " descent=", site.portal_descent_deg,
        " axis=", site.portal_axis_m, " depth=", site.mouth_depth(), " offset=", site.network_offset)
    var frame := site.surface_transform()
    for z in range(-20, 120, 10):
        print("EXPLAIN ground z=", z, " y=", CaveEntrance.ground_in_frame(data, frame, 0, z).y)
    var bend := CavePortal.porch_bend(site)
    for step in 11:
        var point := CavePortal._hermite(bend, step / 10.0) + Vector3.UP * profile.entrance_height_m
        print("EXPLAIN bend ", point, " ground=", CaveEntrance.ground_in_frame(data, frame, point.x, point.z).y)


func _arrive(site: CavePlacement) -> void:
    explorer.placement = site
    explorer._return_to_entrance()
    var deadline := Time.get_ticks_msec() + 60000
    while Time.get_ticks_msec() < deadline:
        if explorer.collision_terrain.stargrot_registry.residency_stats().resident > 0:
            break
        await get_tree().create_timer(0.1).timeout
    check(explorer.collision_terrain.stargrot_registry.residency_stats().resident > 0, "cave collision streamed in")
    for frame in 30:
        await get_tree().physics_frame


## The world's surfaces between two points, never the player's own body (it hovers over the holes).
func _ray(from: Vector3, to: Vector3) -> Dictionary:
    var query := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF, [explorer.player.get_rid()])
    return explorer.get_viewport().get_world_3d().direct_space_state.intersect_ray(query)


func _capture(name: String, pitch: float, lift: float = 0.0) -> void:
    if DisplayServer.get_name() == "headless":
        return
    explorer.player.position += explorer.player.transform.basis.y * lift
    explorer.player.camera_pivot.rotation = Vector3(pitch, 0, 0)
    explorer._placement_light.show()  # the authoring light: night or day, the shapes stay readable
    for frame in 20:
        await RenderingServer.frame_post_draw
    explorer.get_viewport().get_texture().get_image().save_png("res://.stargrot-validation/%s.png" % name)


func _porch(lonlat: Vector2) -> void:
    var profile := CaveWorkbench.preset(1)
    if "--stargrot-zero-noise" in OS.get_cmdline_user_args():
        profile.entrance_noise = 0.0
    profile.entrance_type = "ramp"
    profile.entrance_width_m = 7.0
    profile.entrance_height_m = 12.0
    profile.chamber_height_m = 16.0
    profile.asset_library = _mouth_library()
    var site := await _place(lonlat, profile, 4321)
    if site == null:
        await _explain(lonlat, profile, 4321)
        return
    check(site.portal_axis_m > 0.0, "porch fitted to the relief")
    check(site.portal_descent_deg < 12.0, "a steep flank takes a near-level porch: %.1f°" % site.portal_descent_deg)
    await _arrive(site)
    print("PORTAL COLLISION RESIDENT")
    if "--stargrot-styled-assets" in OS.get_cmdline_user_args():
        var registry: Node = explorer.body.planet_terrain.stargrot_registry
        var group: Node
        var deadline := Time.get_ticks_msec() + 60000
        while group == null and Time.get_ticks_msec() < deadline:
            group = registry.get_node_or_null(site.placement_id.validate_node_name())
            if group == null:
                await get_tree().create_timer(0.1).timeout
        var dressing := 0
        if group:
            for child in group.get_node("Entrance").get_children():
                if child is MultiMeshInstance3D:
                    dressing += child.multimesh.instance_count
        check(dressing > 0, "real asset instances dress the actual porch, not just the network preview")
        print("PORTAL DRESSING count=", dressing)
    var planet: Node3D = explorer.body
    var frame: Transform3D = planet.global_transform * site.surface_transform()
    var axes := CavePortal.porch_axes(site.portal_descent_deg)
    var middle: Vector3 = (axes.up as Vector3) * 12.0 * 0.4
    var outside: Vector3 = middle - (axes.forward as Vector3) * 8.0
    var inside: Vector3 = middle + (axes.forward as Vector3) * site.portal_axis_m * 0.7
    var hit := _ray(frame * outside, frame * inside)
    check(hit.is_empty(), "nothing blocks the mouth: %s" % str(hit.get("collider", "")))
    var beside := Vector3.RIGHT * 7.0
    hit = _ray(frame * (outside + beside), frame * (inside + beside + (axes.forward as Vector3) * 25.0))
    check(not hit.is_empty(), "the flank beside the mouth stays solid")
    var sill: Vector3 = (axes.forward as Vector3) * 2.0
    var floor := _ray(frame * (middle + sill), frame * (sill - (axes.up as Vector3) * 3.0))
    check(not floor.is_empty(), "the porch has a physical floor at its mouth")
    await _capture("portal-porch", -0.05)
    if "--stargrot-porch-debug" in OS.get_cmdline_user_args():
        var debug := StandardMaterial3D.new()
        debug.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        debug.albedo_color = Color.MAGENTA
        var registry: Node = explorer.body.planet_terrain.stargrot_registry
        var entry := registry.get_node(site.placement_id.validate_node_name()).get_node("Entrance/CaveSurface") as MeshInstance3D
        entry.material_overlay = null
        await _capture("portal-porch-no-cover", -0.05)
        entry.material_override = debug
        await _capture("portal-porch-debug", -0.05)
    await _audit_mouth_floor(site)
    await _capture("portal-porch-top", -0.9, 9.0)
    explorer.player.position -= explorer.player.transform.basis.y * 9.0
    explorer.player.position -= explorer.player.transform.basis.z * -22.0  # step back: the mouth in its wall
    await _capture("portal-porch-wide", -0.02, 4.0)


## Sample the displayed sill and the server collider across the cap, including both sides of a cross slope.
func _audit_mouth_floor(site: CavePlacement) -> void:
    var frame: Transform3D = explorer.body.global_transform * site.surface_transform()
    var group: Node = explorer.body.planet_terrain.stargrot_registry.get_node(site.placement_id.validate_node_name())
    var visual := group.get_node("Entrance/CaveSurface") as MeshInstance3D
    var pose: Transform3D = frame.affine_inverse() * visual.global_transform
    var vertices := visual.mesh.get_faces()
    var faces := PackedVector3Array()
    for vertex in vertices:
        faces.append(pose * vertex)
    var missing := 0
    var checked := 0
    var half := site.profile.entrance_width_m * 0.375
    for column in 11:
        for row in 8:
            var z := (row + 0.5) * 0.25
            var point := Vector3(lerpf(-half, half, column / 10.0), -z * tan(deg_to_rad(site.portal_descent_deg)), z)
            var rendered := false
            for index in range(0, faces.size(), 3):
                var at: Variant = Geometry3D.segment_intersects_triangle(point + Vector3.UP * 0.1,
                    point + Vector3.DOWN * 0.1, faces[index], faces[index + 1], faces[index + 2])
                if at != null:
                    rendered = true
                    break
            var hit := _ray(frame * (point + Vector3.UP * 0.3), frame * (point + Vector3.DOWN * 0.3))
            missing += int(not rendered or hit.is_empty())
            checked += 1
    check(missing == 0, "displayed floor and authoritative collider cover all %d sill samples (%d missing)" % [checked, missing])
    print("PORCH DISPLAY FLOOR checked=", checked, " missing=", missing)
    # The fine terrain's cut can also expose narrow wedges beyond the two floor feet.
    # Aim from the real camera at the two locations previously showing only the sky.
    var origin: Vector3 = frame.affine_inverse() * explorer.player.camera.global_position
    for side in [-1.0, 1.0]:
        var target := Vector3(side * (site.profile.entrance_width_m * 0.5 + 0.35), 0, 1.15)
        var end := target + (target - origin) * 0.2
        var rendered := false
        for index in range(0, faces.size(), 3):
            if Geometry3D.segment_intersects_triangle(origin, end, faces[index], faces[index + 1], faces[index + 2]) != null:
                rendered = true
                break
        var physical := _ray(frame * origin, frame * end)
        check(rendered and not physical.is_empty(), "lower corner %s has displayed rock and authoritative collision" % side)


func _doline(lonlat: Vector2) -> void:
    var profile := CaveWorkbench.preset(2)
    profile.entrance_type = "shaft"
    profile.entrance_width_m = 30.0
    profile.asset_library = _mouth_library()
    var site := await _place(lonlat, profile, 8765)
    if site == null:
        return
    check(site.skylight_depth_m > 0.0, "doline throat depth pinned")
    await _arrive(site)
    var planet: Node3D = explorer.body
    var frame: Transform3D = planet.global_transform * site.surface_transform()
    var hit := _ray(frame * Vector3(0, 40, 0), frame * Vector3(0, -site.mouth_depth() - 60.0, 0))
    check(not hit.is_empty(), "the chamber floor catches what falls through the hole")
    if not hit.is_empty():
        var depth := (frame.affine_inverse() * (hit.position as Vector3)).y
        check(depth < -site.skylight_depth_m, "first contact is below the throat, not the ground: %.1f m" % depth)
    var rim := _ray(frame * Vector3(26, 40, 0), frame * Vector3(26, -40, 0))
    check(not rim.is_empty() and (frame.affine_inverse() * (rim.position as Vector3)).y > -3.0, "ground beyond the rim")
    await _capture("portal-doline", -0.75, 22.0)


## Version 9: a porch dives into the plain; its chambers' light shafts open small holes in the ground, and what
## falls through one lands on a chamber floor deep below, not on the ground or a wall.
func _lights(lonlat: Vector2) -> void:
    var profile := CaveWorkbench.preset(1)
    profile.chamber_count = 5
    profile.level_count = 2
    profile.depth_m = maxf(profile.depth_m, 44.0)
    profile.entrance_type = "ramp"
    profile.light_shafts = 3
    profile.asset_library = _mouth_library()
    var cave_seed := -1
    for seed in range(500, 540):
        if not CaveNetwork.layout(profile.snapshot(seed)).get("lights", []).is_empty():
            cave_seed = seed
            break
    check(cave_seed >= 0, "a seed opens light shafts")
    if cave_seed < 0:
        return
    var site := await _place(lonlat, profile, cave_seed)
    if site == null:
        return
    check(not site.light_wells.is_empty(), "light shafts pinned to the relief: %d" % site.light_wells.size())
    print("PORTAL LIGHTS wells=", site.light_wells)
    await _arrive(site)
    var planet: Node3D = explorer.body
    explorer.player.god_mode = true  # hover over the holes and in the chambers while the ground streams in
    for index in site.light_wells.size():
        var well := site.light_wells[index]
        var frame: Transform3D = planet.global_transform * site.surface_transform()
        # Stand over the hole so the ground around it streams in at full detail.
        explorer.player.global_position = frame * Vector3(well.x, 30.0, well.y)
        for step in 90:
            await get_tree().physics_frame
        frame = planet.global_transform * site.surface_transform()
        var hit := _ray(frame * Vector3(well.x, 40.0, well.y), frame * Vector3(well.x, -site.mouth_depth() - 120.0, well.y))
        check(not hit.is_empty(), "shaft %d: a chamber floor catches what falls through the hole" % index)
        if hit.is_empty():
            continue
        var depth := (frame.affine_inverse() * (hit.position as Vector3)).y
        check(depth < -well.w, "shaft %d: first contact below the network's top plane, not the ground: %.1f m" % [index, depth])
        var aside := Vector3(well.x + well.z * 3.0, 0.0, well.y)
        var beside := _ray(frame * (aside + Vector3.UP * 40.0), frame * (aside + Vector3.DOWN * 40.0))
        check(not beside.is_empty(), "shaft %d: the ground beside the hole stays" % index)
        if index == 0:
            await _shaft_captures(site, well, hit.position)


## From the chamber floor looking up the shaft at the sky, the sun at its highest, then the hole from above.
func _shaft_captures(site: CavePlacement, well: Vector4, floor_point: Vector3) -> void:
    if DisplayServer.get_name() == "headless":
        return
    var planet: Node3D = explorer.body
    var best := Globals.debug_time_offset
    var highest := -INF
    for hour in 24:
        Globals.debug_time_offset += Globals.DEBUG_TIME_STEP
        explorer._update_system_frame()
        await get_tree().process_frame
        var frame: Transform3D = planet.global_transform * site.surface_transform()
        var sun := (explorer._universe.get_node("Star") as Node3D).global_position - frame.origin
        var height := frame.basis.y.normalized().dot(sun.normalized())
        if height > highest:
            highest = height
            best = Globals.debug_time_offset
    Globals.debug_time_offset = best
    explorer._update_system_frame()
    print("PORTAL LIGHTS sun height=", rad_to_deg(asin(clampf(highest, -1.0, 1.0))))
    var frame: Transform3D = planet.global_transform * site.surface_transform()
    var local := frame.affine_inverse() * floor_point
    explorer.player.global_position = frame * (local + Vector3(0.0, 0.3, 0.0))
    explorer.player.camera_pivot.rotation = Vector3(1.35, 0, 0)
    explorer._placement_light.hide()  # daylight only: what the shaft lets in
    for step in 30:
        await RenderingServer.frame_post_draw
    explorer.get_viewport().get_texture().get_image().save_png("res://.stargrot-validation/portal-light-up.png")
    explorer.player.global_position = frame * Vector3(well.x - 6.0, 14.0, well.y)
    explorer.player.camera_pivot.rotation = Vector3(-0.95, 0, 0)
    for step in 30:
        await RenderingServer.frame_post_draw
    explorer.get_viewport().get_texture().get_image().save_png("res://.stargrot-validation/portal-light-hole.png")
