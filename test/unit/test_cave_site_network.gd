extends GutTest
## Networked caves (CaveSite, Horizon type "cave"): the prop data round trip, and the terrain's run-time
## registration that replaces the planet-wide catalog — one site at a time, cut, cache-ineligible, refused alone.

const Fixture := preload("res://test/unit/stargrot_fixture.gd")
const CATALOG := "res://levels/stargrot/catalogs/tarsis_3_example.tres"


func before_all() -> void:
    assert_true(CaveNetwork.warm(), "the native cave geometry is available")


func _site(index: int) -> CavePlacement:
    var site := Fixture.placement(Fixture.profile(0))
    site.placement_id = "net-site-%d" % index
    site.longitude_deg = index * 0.05
    Fixture.fit(site, Fixture.data(site))
    return site


func _terrain(site: CavePlacement) -> PlanetTerrain:
    var terrain: PlanetTerrain = autofree(PlanetTerrain.new())
    terrain.planet_data = Fixture.data(site)
    return terrain


func test_every_catalog_cave_survives_the_network_round_trip() -> void:
    var catalog: CaveSiteCatalog = load(CATALOG)
    assert_false(catalog.sites.is_empty())
    for site: CavePlacement in catalog.sites:
        # Through JSON, as the persistence and Horizon carry it (full precision, as fit_cave_items writes it).
        var text := JSON.stringify(site.to_prop_data(), "", false, true)
        var back := CavePlacement.from_prop_data(JSON.parse_string(text))
        assert_not_null(back, site.placement_id)
        if back == null:
            continue
        assert_eq(back.signature(), site.signature(), "%s keeps its geometry identity" % site.placement_id)
        assert_eq(back.profile.asset_library, site.profile.asset_library, "%s keeps its dressing" % site.placement_id)


func test_prop_data_carries_fit_and_light_wells_and_waits_for_required_fields() -> void:
    var site := _site(1)
    site.light_wells = PackedVector4Array([Vector4(1.5, -2.0, 3.0, 12.0)])
    var data := site.to_prop_data()
    assert_true(data.network_offset is Dictionary, "plain values only")
    var back := CavePlacement.from_prop_data(data)
    assert_eq(back.light_wells, site.light_wells)
    assert_eq(back.network_offset, site.network_offset)
    assert_eq(back.signature(), site.signature())
    data.erase("seed")
    assert_null(CavePlacement.from_prop_data(data), "an incomplete update is not a cave yet")


func test_a_library_outside_the_cave_folder_is_refused() -> void:
    var data := _site(1).to_prop_data()
    data["asset_library"] = "res://project.godot"
    assert_null(CavePlacement.from_prop_data(data).profile.asset_library)


func test_runtime_site_is_cut_kept_out_of_the_cache_and_removed() -> void:
    var site := _site(1)
    var terrain := _terrain(site)
    var data := terrain.planet_data
    terrain.register_cave_site(site)
    assert_not_null(terrain.stargrot_registry, "the first networked cave creates the registry")
    assert_eq(data.stargrot_cut_sites.size(), 1, "its openings are cut")
    var finest := 1 << data.max_quadtree_depth
    var pixels := CavePlanetRegistry.site_tiles(data, site, finest)
    assert_false(pixels.is_empty())
    var pixel: int = pixels.keys()[0]
    assert_true(data.chunk_cache_ineligible(finest, pixel), "a runtime cave is in no cache key")
    assert_true(data.chunk_cache_ineligible(finest >> 3, pixel >> 6), "nor are the coarser chunks over it")
    var generation := terrain._pad_generation
    terrain.register_cave_site(site.duplicate(true))
    assert_eq(terrain._pad_generation, generation, "the same definition again rebuilds nothing")
    terrain.unregister_cave_site(site.placement_id)
    assert_true(data.stargrot_cut_sites.is_empty(), "the ground closes again")
    assert_false(data.chunk_cache_ineligible(finest, pixel))
    assert_gt(terrain._pad_generation, generation, "the chunks it reached are rebuilt")


func test_a_refused_cave_never_takes_the_others_with_it() -> void:
    var first := _site(1)
    var terrain := _terrain(first)
    terrain.register_cave_site(first)
    var twin := _site(1)
    twin.placement_id = "net-site-twin"
    terrain.register_cave_site(twin)
    var stale := _site(3)
    stale.terrain_version = "another relief"
    terrain.register_cave_site(stale)
    var ids := terrain.planet_data.stargrot_cut_sites.map(func(s: CavePlacement): return s.placement_id)
    assert_eq(ids, ["net-site-1"], "the overlapping and the stale caves are refused, the first stays")
    assert_true(str(terrain._cave_refusals["net-site-twin"][1]).contains("proche"))
    var moved := _site(5)
    moved.placement_id = "net-site-1"
    terrain.register_cave_site(moved)
    assert_eq(terrain.planet_data.stargrot_cut_sites.size(), 1, "an update replaces the site")
    assert_eq(terrain.planet_data.stargrot_cut_sites[0].longitude_deg, moved.longitude_deg)
