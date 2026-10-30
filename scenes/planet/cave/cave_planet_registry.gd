class_name CavePlanetRegistry
extends Node3D
## Persistent authored definitions; spatial networks subscribe to native chunk residency.
## Cave identity and collision never belong to a single terrain chunk.

const MAX_TRIAL_SITES := 512

var prepared: bool = false
var error_message: String = ""
var _terrain: PlanetTerrain
var _retry_at: int = 0
var _residents: CaveResidentSet
## The catalog's sites, cut since the terrain started (see attach).
var _catalog_cuts: Array[CavePlacement] = []
## Caves registered at run time (networked "cave" props, CaveSite), by placement id.
var _networked: Dictionary = {}
## World-space footprint of every cut site, by placement id: the spacing check of a networked cave. Filled on
## the first networked cave, so a catalog-only body never pays for it.
var _footprints: Dictionary = {}


func ensure_ready() -> bool:
    if _residents != null:
        prepared = _residents.pump()
        return true  # residency must keep advancing while an individual cave is loading
    if prepared:
        return true
    if Time.get_ticks_msec() < _retry_at:
        return false
    _retry_at = Time.get_ticks_msec() + 250
    var data := _terrain.planet_data
    error_message = definition_error(data)
    if not error_message.is_empty():
        prepared = true
        return true  # Invalid optional content must not block the planet.
    for placement in data.cave_placements:
        if placement == null:
            continue
        if not tiles_ready(data, placement):
            return false
    error_message = prepare(data)
    _assemble()
    prepared = true
    return true


static func tiles_ready(data: PlanetData, placement: CavePlacement) -> bool:
    return request_tiles(data, site_tiles(data, placement))


static func request_tiles(data: PlanetData, tiles: Dictionary) -> bool:
    if data.remote_source == null and data.chunk_heightmaps_dir.is_empty():
        return true  # Procedural/test data has no file tiles to request.
    var ready := true
    for ipix: int in tiles:
        if data.remote_source != null:
            if not TileResidency.request_chunk_tiles(data, data.export_nside, ipix):
                ready = false
        elif not TileResidency.tile_available(data, ipix, data.export_nside):
            ready = false
    return ready


static func site_tiles(data: PlanetData, placement: CavePlacement, index_nside: int = -1) -> Dictionary:
    var tiles: Dictionary = {}
    var network := CaveNetwork.layout(placement.profile.snapshot(placement.seed))
    var offset := placement.network_offset
    var half_width := maxf(absf(network.footprint.position.x), absf(network.footprint.end.x)) + 3.0 + absf(offset.x)
    # The network sits at its fitted offset; the porch between the mouth and it is covered from z = -ramp.
    var shifted := placement.surface_transform() * Transform3D(Basis.IDENTITY, Vector3(offset.x, 0.0, 0.0))
    _collect_tiles(data, shifted, minf(-placement.ramp_length_m, offset.z - placement.ramp_length_m),
        placement.profile.length_m + maxf(0.0, offset.z), half_width, tiles, index_nside)
    for opening: Dictionary in placement.openings():
        # Exterior rocks reach 6 m beyond the rim, plus their mesh extent. Fetch their ground
        # and retain their colliders when the player stands beside, rather than inside, the opening.
        var library := placement.profile.asset_library
        var apron := 10.0 if opening.kind != "porch" and library != null and library.decoration_rules().any(
            func(rule: CaveDecorationRule): return rule != null and rule.support == "entrance_ground") else 0.0
        _collect_tiles(data, opening.frame, -float(opening.length) - apron, float(opening.get("back", 0.0)) + apron,
            float(opening.width) * 0.5 + apron, tiles, index_nside)
    return tiles


static func _collect_tiles(data: PlanetData, frame: Transform3D, start_z: float, end_z: float,
        half_width: float, tiles: Dictionary, index_nside: int = -1) -> void:
    var steps := int(ceil((end_z - start_z) / 10.0))
    var across := int(ceil(half_width * 2.0 / 20.0))
    for row in steps + 1:
        var z := lerpf(start_z, end_z, float(row) / maxi(steps, 1))
        for column in across + 1:
            var x := lerpf(-half_width, half_width, float(column) / maxi(across, 1))
            var direction := (frame * Vector3(x, 0.0, z)).normalized()
            tiles[HEALPix.vec2pix_nest(data.export_nside if index_nside < 0 else index_nside, direction)] = true


static func definition_error(data: PlanetData) -> String:
    return placements_error(data.cave_placements, data)


static func placements_error(placements: Array[CavePlacement], data: PlanetData) -> String:
    if placements.size() > MAX_TRIAL_SITES:
        return "La collection accepte jusqu’à %d sites par corps." % MAX_TRIAL_SITES
    var ids: Dictionary = {}
    var bounds: Array[AABB] = []
    for placement in placements:
        if placement == null:
            continue
        var error := placement.validation_error(data)
        if not error.is_empty():
            return error
        if ids.has(placement.placement_id):
            return "Deux grottes portent le même identifiant."
        ids[placement.placement_id] = true
        var footprint := placement.footprint_bounds()
        for previous in bounds:
            if footprint.intersects(previous):
                return "Cette grotte est trop proche d’une autre : choisissez un emplacement plus éloigné."
        bounds.append(footprint)
    return ""


static func prepare(data: PlanetData) -> String:
    CaveNetwork.warm()
    data.stargrot_plans.clear()
    var error := definition_error(data)
    if not error.is_empty():
        return error
    var plans: Array[Dictionary] = []
    for placement in data.cave_placements:
        if placement == null:
            continue
        var plan := build_plan(data, placement)
        if not str(plan.error).is_empty():
            return plan.error
        plans.append(plan)
    data.stargrot_plans = plans  # Publish only a completely validated plan.
    return ""


## CPU geometry and canonical heights only, like the native terrain workers.
## The caller must warm the native modules and acquire tiles before dispatching.
static func build_plan(data: PlanetData, placement: CavePlacement, dressing: Dictionary = {}) -> Dictionary:
    var cave := CaveGenerator.build(placement.profile.snapshot(placement.seed))
    if not str(cave.error).is_empty():
        return {"error": cave.error}
    var entrance := CaveEntrance.build(data, placement, cave)
    if not dressing.is_empty():
        cave["decoration_plan"] = CavePreviewBuilder.prepare_decorations(cave, dressing)
        entrance["decoration_plan"] = CavePreviewBuilder.prepare_decorations(entrance, dressing)
    return {"placement": placement, "cave": cave, "entrance": entrance,
        "error": CaveEntrance.site_error(data, placement, cave)}


static func attach(terrain: PlanetTerrain) -> CavePlanetRegistry:
    CaveNetwork.warm()
    var registry := CavePlanetRegistry.new()
    registry.name = "StargrotCaves"
    registry._terrain = terrain
    terrain.add_child(registry)
    registry.error_message = definition_error(terrain.planet_data)
    if registry.error_message.is_empty():
        # Cuts depend on persistent definitions, never on which meshes happen to be resident.
        registry._catalog_cuts = terrain.planet_data.cave_placements.duplicate()
        registry._publish_cuts()
        # Networks subscribe to native chunk residency: only the caves near the player are meshed.
        registry._ensure_residents()
    return registry


## The networked cave registered under [param id], or null.
func networked_site(id: String) -> CavePlacement:
    return _networked.get(id)


## Add or replace a cave that arrived at run time. Returns why it was refused ("" when it is in): a site is
## judged alone, so one bad cave never takes the others' cuts away. The caller rebuilds the chunks it reaches.
func set_site(placement: CavePlacement) -> String:
    var id := placement.placement_id
    var error := placement.validation_error(_terrain.planet_data)
    if error.is_empty() and _catalog_cuts.any(func(site: CavePlacement): return site.placement_id == id):
        error = "Identifiant déjà porté par une grotte du catalogue."
    if not error.is_empty():
        return error
    if _footprints.is_empty():
        for site in _catalog_cuts:
            _footprints[site.placement_id] = site.footprint_bounds()
    var footprint := placement.footprint_bounds()
    for other: String in _footprints:
        if other != id and footprint.intersects(_footprints[other]):
            return "Trop proche de la grotte %s." % other
    _footprints[id] = footprint
    _networked[id] = placement
    _publish_cuts()
    _ensure_residents()
    _residents.add_site(placement)
    return ""


## Drop a cave registered at run time; false when there was none under [param id].
func remove_site(id: String) -> bool:
    if not _networked.has(id):
        return false
    _networked.erase(id)
    _footprints.erase(id)
    _publish_cuts()
    if _residents != null:
        _residents.remove_site(id)
    return true


## A networked cave whose network cannot be built is dropped (its ground stays whole) rather than left holding
## back every chunk it reaches; a catalog cave keeps them waiting, as before.
func site_failed(id: String, error: String) -> void:
    if _networked.has(id):
        _terrain.drop_failed_cave_site.call_deferred(id, error)


## Copy-on-write: chunk workers read the published array, so a new one replaces it in one assignment.
func _publish_cuts() -> void:
    var cuts: Array[CavePlacement] = _catalog_cuts.duplicate()
    for site: CavePlacement in _networked.values():
        cuts.append(site)
    _terrain.planet_data.stargrot_cut_sites = cuts


## An invalid catalog is never cut (see attach), but the networked caves still get their residency.
func _ensure_residents() -> void:
    if _residents == null:
        _residents = CaveResidentSet.new()
        _residents.initialize(self, _terrain)


func _assemble() -> void:
    for plan: Dictionary in _terrain.planet_data.stargrot_plans:
        assemble_plan(plan)


func assemble_plan(plan: Dictionary) -> Node3D:
    var group := Node3D.new()
    group.name = str(plan.placement.placement_id).validate_node_name()
    add_child(group)
    var placement: CavePlacement = plan.placement
    var cave := CavePreviewBuilder.instantiate(plan.cave, placement.profile.asset_library,
        not _terrain.is_server, _terrain.is_server, placement.network_origin())
    cave.name = placement.placement_id.validate_node_name()
    cave.transform = placement.cave_transform()
    group.add_child(cave)
    var entrance := CavePreviewBuilder.instantiate(plan.entrance, placement.profile.asset_library,
        not _terrain.is_server, _terrain.is_server)
    entrance.name = "Entrance"
    entrance.transform = placement.surface_transform()
    group.add_child(entrance)
    if not _terrain.is_server:
        CaveGroundCover.apply(entrance, _terrain.planet_data, placement.surface_direction())
    if not _terrain.is_server and Globals.is_stargrot_explorer():
        # Authoring lights are excluded from normal gameplay: production caves use the game's lighting.
        var rooms: Array = plan.cave.graph.rooms
        var stride := maxi(1, int(ceil(rooms.size() / 6.0)))
        for index in range(0, rooms.size(), stride):
            var lamp := OmniLight3D.new()
            lamp.position = (rooms[index].a as Vector3) + Vector3.UP * 2.4
            lamp.light_color = Color(0.75, 0.87, 1.0)
            lamp.light_energy = 3.0
            lamp.omni_range = 12.0
            cave.add_child(lamp)
    return group


func _process(_delta: float) -> void:
    if _residents != null:
        ensure_ready()


func _exit_tree() -> void:
    retire()


func retire() -> void:
    set_process(false)
    if _residents != null:
        _residents.shutdown()
        _residents = null


func residency_stats() -> Dictionary:
    return _residents.stats() if _residents else {"resident": _terrain.planet_data.stargrot_plans.size(),
        "definitions": _terrain.planet_data.cave_placements.size(), "workers": 0}


func ready_for_chunk(key: String) -> bool:
    ensure_ready()
    return _residents.ready_for_chunk(key) if _residents else prepared


## Inside a resident cave's rock: its network's air, a porch's gallery, or a doline throat or light shaft under
## the ground; not an open-air hollow. From there the ground is only seen through the openings (PlanetTerrain
## hides its stale chunks, see _hide_stale_in_caves).
static func inside_rock(data: PlanetData, planet_point: Vector3) -> bool:
    for plan: Dictionary in data.stargrot_plans:
        var placement: CavePlacement = plan.placement
        if CaveGenerator.contains(plan.cave, placement.cave_transform().affine_inverse() * planet_point):
            return true
        if CaveEntrance.in_gallery(data, placement, planet_point):
            return true
    return false


## Only the actual cavity exempts a body from the below-surface rescue.
## Rocks may deflect a player toward a wall; the whole interior remains safe.
static func contains(data: PlanetData, planet_point: Vector3) -> bool:
    for plan: Dictionary in data.stargrot_plans:
        var placement: CavePlacement = plan.placement
        var local := placement.cave_transform().affine_inverse() * planet_point
        if CaveEntrance.contains(data, placement, planet_point):
            return true
        if CaveGenerator.contains(plan.cave, local):
            return true
    return false
