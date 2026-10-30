extends GutTest

const Fixture := preload("res://test/unit/stargrot_fixture.gd")

class FlatData extends PlanetData:
    func crack_aware_surface_dist(_direction: Vector3, _nside: int = -1, _spacing: float = 0.0) -> float:
        return radius


class AssemblyTerrain extends PlanetTerrain:
    var assembled_keys: Array[String] = []

    func _assemble_visual_chunk(info: Dictionary, _mesh: ArrayMesh) -> void:
        assembled_keys.append(info.key)


class PendingCave extends CavePlanetRegistry:
    var cavity_ready: bool = false

    func ready_for_chunk(key: String) -> bool:
        return cavity_ready or key != "pending"


func test_cut_visual_chunks_wait_for_the_cave_without_starving_unrelated_ground() -> void:
    var terrain := AssemblyTerrain.new()
    var caves := PendingCave.new()
    terrain.add_child(caves)
    terrain.stargrot_registry = caves
    terrain._residency_keys = {"pending": true, "unrelated": true}
    for key in ["pending", "unrelated"]:
        var info := {"key": key, "center": Vector3(0, 0, 1 if key == "pending" else 10)}
        terrain._queue_insert(terrain._assemble_queue, {"info": info, "mesh": ArrayMesh.new()}, info.center)
    terrain._process_assemble_queue()
    assert_eq(terrain.assembled_keys, ["unrelated"], "nearby pending cave does not block other terrain")
    assert_eq(terrain._assemble_queue.size(), 1, "cut mesh retained until its cave exists")
    terrain._residency_keys = {}
    terrain._process_assemble_queue()
    assert_true(terrain._assemble_queue.is_empty(), "leaving discards a mesh waiting for an unwanted cave")
    var returning := {"key": "pending", "center": Vector3(0, 0, 1)}
    terrain._queue_insert(terrain._assemble_queue, {"info": returning, "mesh": ArrayMesh.new()}, returning.center)
    terrain._residency_keys = {"pending": true}
    caves.cavity_ready = true
    terrain._process_assemble_queue()
    assert_eq(terrain.assembled_keys, ["unrelated", "pending"], "displayed hole and cavity become available together")
    assert_true(terrain._assemble_queue.is_empty())
    terrain.free()


func test_refit_revalidates_new_terrain_without_mutating_legacy_sites() -> void:
    var data := FlatData.new()
    data.planet_name = "stargrot_test"
    data.radius = 6356000.0
    data.chunk_data_version = "new-relief"
    data.relief_signature = "native-v68"
    var legacy := CavePlacement.new()
    legacy.planet_name = data.planet_name
    legacy.terrain_version = "old-relief"
    legacy.surface_height_m = 500.0
    legacy.longitude_deg = -39.58
    legacy.profile = CaveWorkbench.preset(1)
    legacy.profile.generator_version = 8  # an older definition: the refit keeps its version and geometry
    var before := legacy.signature()
    var direction := legacy.surface_direction()
    var population := CavePopulation.new()
    add_child_autofree(population)
    var report := await population.refit(data, [legacy])
    assert_eq(report.rejected, {})
    assert_eq(report.sites.size(), 1)
    assert_eq(legacy.signature(), before, "original stays intact until publication")
    if report.sites.is_empty(): return
    var fitted: CavePlacement = report.sites[0]
    assert_eq(fitted.format_version, 2)
    assert_eq(fitted.terrain_version, data.chunk_data_version)
    assert_eq(fitted.terrain_relief_signature, data.relief_signature)
    assert_eq(fitted.surface_height_m, 0.0)
    assert_lt(fitted.surface_direction().distance_to(direction), 0.000001)
    assert_eq(fitted.validation_error(data), "")
    var cave := CaveGenerator.build(fitted.profile.snapshot(fitted.seed))
    assert_eq(CaveEntrance.site_error(data, fitted, cave), "")


func test_cancelled_refit_publishes_nothing() -> void:
    var data := FlatData.new()
    data.planet_name = "stargrot_test"
    data.radius = 6356000.0
    data.chunk_data_version = "new-relief"
    var site := CavePlacement.new()
    site.planet_name = data.planet_name
    site.terrain_version = "old-relief"
    site.profile = CaveWorkbench.preset(1)
    var before := site.signature()
    var population := CavePopulation.new()
    add_child_autofree(population)
    population.progress.connect(func(_accepted, _requested, _attempted, _message): population.cancelled = true)
    var report := await population.refit(data, [site])
    assert_true(report.cancelled)
    assert_true(report.sites.is_empty())
    assert_eq(site.signature(), before)


func test_native_relief_change_invalidates_sites_even_with_unchanged_height_tiles() -> void:
    var site: CavePlacement = Fixture.placement()
    var data: PlanetData = Fixture.data(site)
    Fixture.fit(site, data)
    assert_eq(site.validation_error(data), "")
    var before := site.signature()
    data.relief_signature = "native-v68"
    assert_false(site.validation_error(data).is_empty(), "legacy fit cannot cut updated native relief")
    site.terrain_relief_signature = data.relief_signature
    assert_eq(site.validation_error(data), "")
    assert_ne(site.signature(), before, "terrain/collision cache identity includes the pinned native relief")
    data.relief_signature = "native-v69"
    assert_false(site.validation_error(data).is_empty(), "same height data with a new carve still requires refitting")
