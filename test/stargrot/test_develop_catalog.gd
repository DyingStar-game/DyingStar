extends Node3D
## Test the Tarsis III caves through native client/server terrain initialization, with no atelier.
##
## The caves are networked props whose positions are not public: they are read from the private import file
## written by tools/stargrot/fit_cave_items.tscn (DS_CAVE_ITEMS, default below). Without it the test is skipped.

const ITEMS := "~/dyingstar-private/caves/tarsis_3_cave_items.json"
var checks: int = 0
var failures: Array[String] = []
var load_ms: Dictionary = {}


func _ready() -> void:
    preload("res://test/stargrot/test_cache.gd").use_directory("StarGrotteCatalogTests")
    _run.call_deferred()


func check(condition: bool, label: String) -> void:
    checks += 1
    if not condition:
        failures.append(label)
        push_error(label)


func _run() -> void:
    var path := OS.get_environment("DS_CAVE_ITEMS")
    if path.is_empty():
        path = ITEMS.replace("~", OS.get_environment("HOME"))
    if not FileAccess.file_exists(path):
        print("STARGROT DEVELOP CATALOG skipped: no private cave import file at ", path)
        get_tree().quit(0)
        return
    var catalog := _catalog(path)
    check(not catalog.sites.is_empty(), "every cave of the import file reads back")
    if catalog.sites.is_empty():
        get_tree().quit(1)
        return
    var original: PlanetData = SystemScenes.root_properties("res://scenes/systems/tarsis/tarsis_3.tscn").planet_data
    # Tarsis III's caves are networked props (CaveSite) now: the scene must not cut them a second time.
    check(original.cave_catalog == null, "normal game scene leaves the caves to the network")
    check(original.cave_placements.is_empty(), "no duplicate inline cave definitions")
    var terrains: Array[PlanetTerrain] = []
    var anchor := catalog.sites[0].surface_transform().origin
    var first_id := catalog.sites[0].placement_id
    for server_mode in [false, true]:
        var data: PlanetData = original.duplicate(true)
        data.cave_catalog = catalog
        var terrain := PlanetTerrain.new()
        terrain.name = "ServerTerrain" if server_mode else "ClientTerrain"
        add_child(terrain)
        terrain.initialize(data, server_mode)
        terrain.position = -anchor
        terrain.set_process(false)
        terrain.set_physics_process(false)
        terrains.append(terrain)
        check(data.cave_placements.size() == catalog.sites.size(), "native initialization reads catalog")
        check(CavePlanetRegistry.definition_error(data).is_empty(), "current native relief accepts catalog")
        check(terrain.stargrot_registry != null and terrain.stargrot_registry.residency_stats().resident == 0,
            "catalog creates zero cave meshes before native residency")
        check(terrain._chunk_cache.version.ends_with(data.stargrot_signature()), "cave cache suffix follows native suffixes")
        if not server_mode:
            check(terrain._chunk_cache.version.contains("_far50km"), "native distant cache version survives")
        var detail_nside := data.collision_detail_nside()
        var tiles := CavePlanetRegistry.site_tiles(data, catalog.sites[0], detail_nside)
        var key := "hp_n%d_p%d" % [detail_nside, tiles.keys()[0]]
        terrain._publish_residency({key: true})
        # The first authored room is 124 m wide: its measured full geometry/cover check exceeded
        # the old 30 s demo deadline. Keep a bounded allowance and report the actual loading cost.
        var started := Time.get_ticks_msec()
        var deadline := started + 90000
        while _site_plan(terrain, first_id).is_empty() and Time.get_ticks_msec() < deadline:
            terrain.stargrot_registry.ensure_ready()
            await get_tree().process_frame
        load_ms["server" if server_mode else "client"] = Time.get_ticks_msec() - started
        check(not _site_plan(terrain, first_id).is_empty(), "native residency loads the requested catalog cave")
        check(not data.stargrot_plans.is_empty(), "geometry available to native terrain")
    check(terrains[0].planet_data.stargrot_signature() == terrains[1].planet_data.stargrot_signature(),
        "client and server share catalog signature")
    var client := _site_plan(terrains[0], first_id)
    var server := _site_plan(terrains[1], first_id)
    if not client.is_empty() and not server.is_empty():
        check(client.cave.faces == server.cave.faces,
            "client and server generate identical geometry")
    for terrain in terrains:
        terrain._publish_residency({})
        await get_tree().process_frame
        check(terrain.stargrot_registry.residency_stats().resident == 0, "native residency releases cave")
        terrain.free()
    var file := FileAccess.open("res://test/stargrot/develop-catalog-results.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"checks": checks, "failures": failures,
        "catalog_sites": catalog.sites.size(), "load_ms": load_ms}, "  "))
    file.close()
    print("STARGROT DEVELOP CATALOG ", checks, " checks; failures=", failures)
    get_tree().quit(0 if failures.is_empty() else 1)


## The import file's caves as an in-memory catalog (never saved: their positions stay private).
static func _catalog(path: String) -> CaveSiteCatalog:
    var catalog := CaveSiteCatalog.new()
    var items: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
    for item: Variant in items if items is Array else []:
        var site := CavePlacement.from_prop_data((item as Dictionary).get("object_data", {}) if item is Dictionary else {})
        if site != null:
            catalog.sites.append(site)
    return catalog


## Match by stable ID: several cave workers can finish in a different order on client and server.
func _site_plan(terrain: PlanetTerrain, id: String) -> Dictionary:
    for plan: Dictionary in terrain.planet_data.stargrot_plans:
        if plan.placement.placement_id == id:
            return plan
    return {}
