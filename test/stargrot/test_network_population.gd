extends Node
## Real generated geometry/collision, bounded native residency, and a reproducible 200-site batch.

class FlatData extends PlanetData:
    func crack_aware_surface_dist(_direction: Vector3, _nside: int = -1, _spacing: float = 0.0) -> float:
        return radius

    func first_zone_at(_dir: Vector3) -> Dictionary:
        return {}

var checks: int = 0
var failures: Array[String] = []


func _ready() -> void:
    _run.call_deferred()


func check(condition: bool, label: String) -> void:
    checks += 1
    if not condition:
        failures.append(label)
        push_error(label)


func _run() -> void:
    check(CaveNetwork.warm(), "native geometry module available")
    var profile := CaveWorkbench.preset(1)
    profile.level_count = 3
    profile.depth_m = 40.0
    profile.pillar_count = 6
    profile.light_shafts = 0
    var cave := CaveGenerator.build(profile.snapshot(42))
    check(cave.error.is_empty(), "network generated")
    if not cave.error.is_empty():
        get_tree().quit(1)
        return
    var geometry := CavePreviewBuilder.instantiate(cave, profile.asset_library, false, true)
    add_child(geometry)
    await get_tree().physics_frame
    await get_tree().physics_frame
    var space := geometry.get_world_3d().direct_space_state
    for room: Dictionary in cave.graph.rooms:
        # Floors carry tilt, relief, terraces or a basin: the first air above the chamber's centre, on the density
        # surface itself (contains() adds 0.4 cell of slack for terrain cutting).
        var height := -10.0
        while height < float(room.size.y) and float(cave.sampler.call("Sample", room.a + Vector3.UP * height)) <= 0.0:
            height += 0.1
        var floor_point: Vector3 = room.a + Vector3.UP * height
        check(height < float(room.size.y), "open chamber, level %d" % room.level)
        var ray := PhysicsRayQueryParameters3D.create(floor_point + Vector3.UP * 1.5, floor_point + Vector3.DOWN * 2)
        var hit := space.intersect_ray(ray)
        check(not hit.is_empty() and absf(hit.position.y - floor_point.y) < 0.6, "physical floor in every chamber")
    for pillar: Dictionary in cave.graph.pillars:
        var center: Vector3 = pillar.a + Vector3.UP * float(pillar.size.y) * 0.5
        check(not CaveGenerator.contains(cave, center, 0), "pillar volume is solid")
        var ray := PhysicsRayQueryParameters3D.create(center - Vector3.FORWARD * 5, center + Vector3.FORWARD * 5)
        var hit := space.intersect_ray(ray)
        check(not hit.is_empty() and hit.position.distance_to(center) < 3, "pillar has a real collision wall")
    check(CavePopulation.accessible_entry_error(cave).is_empty(), "route from mouth to first room fits a human")
    geometry.free()
    var index := {7: ["one"], 8: ["two"]}
    var requested := CaveResidentSet.desired_sites({"hp_n64_p112": true, "hp_n64_p113": true, "hp_n8_p7": true}, 16, index)
    check(requested == {"one": 2}, "fine native leaves reference-count the same cave; orbital leaves ignored")
    var data := FlatData.new()
    data.planet_name = "stargrot_batch_fixture"
    data.radius = 6356000
    data.chunk_data_version = "fixture-v1"
    var population := CavePopulation.new()
    add_child(population)
    population.progress.connect(func(accepted: int, _requested: int, _attempted: int, message: String):
        if accepted % 20 == 0 and message == "Site validé automatiquement":
            print("BATCH accepted=", accepted))
    var start := Time.get_ticks_msec()
    var report := await population.generate(data, [], 200, 20261005)
    print("BATCH complete count=", report.sites.size(), " ms=", Time.get_ticks_msec() - start, " rejected=", report.rejected)
    check(report.sites.size() == 200, "200 accepted sites without manual positioning")
    var narrow := 0
    var shafts := 0
    var sites: Array[CavePlacement] = []
    sites.assign(report.sites)
    for site in sites:
        narrow += int(site.profile.entrance_height_m < 2)
        shafts += int(site.profile.entrance_type == "shaft")
    check(sites.all(func(site: CavePlacement): return site.profile.generator_version == CaveGenerator.VERSION), "batch uses current forms")
    check(sites.all(func(site: CavePlacement): return ["porch", "skylight"].has(site.openings()[0].kind)),
        "every mouth is a porch or a doline")
    check(sites.any(func(site: CavePlacement): return site.profile.chamber_width_m >= 100), "batch includes occasional giant halls")
    check(sites.any(func(site: CavePlacement): return site.profile.bridge_count > 0), "batch includes rock spans")
    check(sites.any(func(site: CavePlacement):
        return not (CaveNetwork.layout(site.profile.snapshot(site.seed)).pits as Array).is_empty()), "batch includes passable pits")
    check(CavePlanetRegistry.placements_error(sites, data).is_empty(), "entire batch has valid separated footprints")
    var replay := await population.generate(data, [], 5, 20261005)
    var same: bool = replay.sites.size() == 5
    for i in replay.sites.size():
        same = same and replay.sites[i].signature() == sites[i].signature()
    check(same, "same batch seed reproduces sites and terrain fitting")
    var cancel := func(accepted: int, _requested: int, _attempted: int, _message: String):
        if accepted >= 2: population.cancelled = true
    population.progress.connect(cancel)
    var stopped := await population.generate(data, [], 10, 7)
    check(stopped.cancelled and stopped.sites.is_empty(), "cancel discards staged changes")
    population.progress.disconnect(cancel)
    var catalog := CaveSiteCatalog.new()
    catalog.sites = sites
    var path := "user://stargrot_test_catalog.tres"
    check(ResourceSaver.save(catalog, path) == OK, "runtime catalog exports")
    var restored: CaveSiteCatalog = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
    check(restored.sites.size() == 200 and restored.sites[-1].signature() == sites[-1].signature(), "200-site catalog round trip")
    check(not FileAccess.get_file_as_string(path).contains("tools/stargrot"), "catalog has no authoring dependency")
    DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
    await _residency(data, sites)
    population.free()
    var result := {"checks": checks, "failures": failures, "accepted": sites.size(), "narrow": narrow, "shafts": shafts,
        "elapsed_ms": Time.get_ticks_msec() - start, "rejected": report.rejected}
    var file := FileAccess.open("res://test/stargrot/network-population-results.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(result, "  "))
    file.close()
    print("STARGROT NETWORK POPULATION ", result)
    get_tree().quit(0 if failures.is_empty() else 1)


func _residency(data: PlanetData, sites: Array[CavePlacement]) -> void:
    var terrain := PlanetTerrain.new()
    terrain.planet_data = data
    terrain.is_server = true
    data.cave_placements = sites
    add_child(terrain)
    terrain.set_process(false)
    terrain.set_physics_process(false)
    var registry := CavePlanetRegistry.attach(terrain)
    check(registry.residency_stats().resident == 0, "200 definitions load zero cave meshes in orbit")
    var tiles := CavePlanetRegistry.site_tiles(data, sites[0])
    var key := "hp_n%d_p%d" % [data.export_nside, tiles.keys()[0]]
    # Every site whose footprint reaches that tile, the first one included (neighbours may share it).
    var tile: Variant = tiles.keys()[0]
    var nearby := sites.filter(func(site: CavePlacement): return CavePlanetRegistry.site_tiles(data, site).has(tile)).size()
    terrain._residency_keys = {key: true}
    terrain.residency_changed.emit(PackedStringArray([key]), PackedStringArray())
    var deadline := Time.get_ticks_msec() + 15000
    while registry.residency_stats().resident < nearby and Time.get_ticks_msec() < deadline:
        registry.ensure_ready()
        await get_tree().process_frame
    check(registry.residency_stats().resident == nearby, "native residency event loads exactly the nearby caves")
    check(registry.ready_for_chunk(key), "surface collider released only after cavity collider exists")
    var stable := true
    for probe in 100:
        stable = registry.ready_for_chunk(key) and stable
    check(stable and registry.residency_stats().workers == 0,
        "repeated terrain queries reuse completed residency without starting work")
    check(data.stargrot_placements().size() == 200, "terrain cuts independent of resident meshes")
    terrain._residency_keys = {}
    terrain.residency_changed.emit(PackedStringArray(), PackedStringArray([key]))
    check(registry.residency_stats().resident == 0 and data.stargrot_plans.is_empty(), "leaving unloads mesh/collider/containment")
    check(registry.ensure_ready() and registry.prepared, "empty residency becomes ready immediately")
    # Leave and return during the same frame, after the pump cached its ready result.
    terrain._residency_keys = {key: true}
    terrain.residency_changed.emit(PackedStringArray([key]), PackedStringArray())
    check(not registry.ready_for_chunk(key), "returning in the same frame closes the collider gate until rebuilding")
    deadline = Time.get_ticks_msec() + 15000
    while registry.residency_stats().resident < nearby and Time.get_ticks_msec() < deadline:
        registry.ensure_ready()
        await get_tree().process_frame
    check(registry.residency_stats().resident == nearby and registry.ready_for_chunk(key),
        "same-frame residency changes eventually restore the nearby colliders")
    terrain._residency_keys = {}
    terrain.residency_changed.emit(PackedStringArray(), PackedStringArray([key]))
    registry.retire()
    check(not terrain.residency_changed.has_connections(), "retired registry cannot republish stale plans")
    terrain.free()
