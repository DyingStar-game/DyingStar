class_name CaveFitter
extends Node
## Fits caves to the relief: the porch or doline, the network's depth and offset, the light shafts
## (CavePortal.fit), then the checks that the whole network stays under the ground (CaveEntrance.site_error).
## Shared by the server, which fits a networked cave a player comes near (CaveSite), the offline tool
## tools/stargrot/fit_cave_items.tscn and the StarGrotte workbench (CavePopulation extends it).
## Every ground read of a fit goes through the terrain's native sampler (CaveGround).

signal progress(accepted: int, requested: int, attempted: int, message: String)

var cancelled: bool = false
var _task: int = -1
var _group: int = -1
var _result: Array = [{}]


func _exit_tree() -> void:
    if _task >= 0:
        WorkerThreadPool.wait_for_task_completion(_task)
    if _group >= 0:
        WorkerThreadPool.wait_for_group_task_completion(_group)



## Refit a copy; failed sites and cancellation leave the original definitions intact.
func refit(data: PlanetData, sites: Array[CavePlacement]) -> Dictionary:
    cancelled = false
    if not CaveNetwork.warm():
        return {"sites": [], "rejected": {"Module de géométrie indisponible": 1}, "cancelled": false}
    var fitted: Array[CavePlacement] = []
    var rejected: Dictionary = {}
    for index in sites.size():
        if cancelled:
            break
        var site: CavePlacement = sites[index].duplicate(true)
        site.migrate_coordinates()
        site.planet_radius_m = data.radius
        site.terrain_version = data.chunk_data_version
        progress.emit(fitted.size(), sites.size(), index + 1, "Recalage sur le relief actuel…")
        var prepared := await prepare_site(data, site)
        var error := str(prepared.error)
        if error.is_empty():
            fitted.append(site)
        else:
            _reject(rejected, site.placement_id + " : " + error)
    if cancelled:
        fitted.clear()
    return {"sites": fitted, "rejected": rejected, "cancelled": cancelled}


## Single publication gate for click, coordinates, batch and refit.
## Only this staged placement is mutated; callers publish atomically after overlap checks.
func prepare_site(data: PlanetData, site: CavePlacement, adapt: bool = false,
        pois: Array[Dictionary] = []) -> Dictionary:
    var error := site.definition_error()
    if not error.is_empty():
        return {"error": error}
    if pois.is_empty():
        pois = StarMapPoi.load_for(data.planet_name)
    if excluded_by_poi(site, pois):
        return {"error": "Zone de bâtiment ou de POI"}
    if not await _wait_tiles(data, site, adapt):
        return {"error": "Tuiles indisponibles"}
    var direction := site.surface_direction()
    var biome := str(data.first_zone_at(direction).get("biome_type", "")).to_lower()
    if excluded_biome(biome):
        return {"error": "Eau, lave active ou zone bâtie"}
    site.surface_height_m = data.crack_aware_surface_dist(direction, data.export_nside) - data.radius
    var relief := {"label": "placement manuel"}
    if adapt:
        relief = topography(data, site)
        site.heading_deg = relief.heading
        site.profile.entrance_type = entrance_for(biome, float(relief.slope), site.seed)
        apply_family(site.profile, biome)
        # An oriented footprint may touch tiles that the initial proposal did not.
        if not await _wait_tiles(data, site):
            return {"error": "Tuiles du réseau orienté indisponibles"}
    elif site.profile.entrance_type != "shaft":
        # A porch is bored into the relief: on any real slope it faces uphill whatever the cursor's heading.
        if not await _wait_tiles(data, site, true):
            return {"error": "Tuiles du relief indisponibles"}
        var slope := topography(data, site)
        if float(slope.slope) >= 0.1:
            site.heading_deg = slope.heading
            if not await _wait_tiles(data, site):
                return {"error": "Tuiles du réseau orienté indisponibles"}
    var cave := await build_geometry(site.profile.snapshot(site.seed))
    error = str(cave.error)
    if error.is_empty():
        error = await fit_entrance(data, site, cave)  # never optional: an entrance only exists fitted
    if error.is_empty() and not await _wait_tiles(data, site):
        error = "Tuiles du raccord indisponibles"
    if error.is_empty():
        error = site.validation_error(data)
    if error.is_empty():
        error = await entrance_error(data, site, cave)
    if error.is_empty() and excluded_by_poi(site, pois):
        error = "Raccord trop proche d’un bâtiment ou POI"
    if cancelled:
        error = "Placement annulé"
    return {"error": error, "relief": relief}


static func excluded_biome(biome: String) -> bool:
    # Geological lava fields may be cooled rock; only explicitly active lava is excluded.
    for token in ["ocean", "lake", "river", "sea", "urban", "lava_lake", "active_lava"]:
        if token in biome:
            return true
    return biome == "lava"


static func entrance_for(biome: String, slope: float, variant: int = 0) -> String:
    if slope > 0.12:
        return "ramp"
    if "volcan" in biome or "basalt" in biome or "lava" in biome:
        return "shaft"
    if slope > 0.04:
        return "hangar"
    # Flat ground: a doline, or a porch diving into the plain, one or the other by seed.
    return "ramp" if variant % 2 == 1 else "shaft"


func build_geometry(spec: Dictionary) -> Dictionary:
    return await _run_cpu(func(): return CaveGenerator.build(spec))


## Pins the porch or doline, and the light shafts, to the relief (CavePortal.fit). A second pass runs once the tiles under
## the fitted network are resident, since the first one may have read heights where none were loaded yet.
func fit_entrance(data: PlanetData, site: CavePlacement, cave: Dictionary) -> String:
    for attempt in 2:
        var result := await _run_cpu(func(): return CavePortal.fit(data, site, cave), data)
        if not str(result.error).is_empty():
            return str(result.error)
        site.apply_fit(result)
        if not await _wait_tiles(data, site):
            return "Tuiles du réseau ajusté indisponibles"
    return ""


## CaveEntrance.site_error, its roof points shared out over the worker threads (one ground frame each).
func entrance_error(data: PlanetData, site: CavePlacement, cave: Dictionary) -> String:
    var points := CaveGenerator.cover_points(cave)
    @warning_ignore("integer_division")
    var batches := clampi(points.size() / 2048, 1, OS.get_processor_count() * 2)
    var out: Array = []  # one Array per batch: each thread writes its own
    for batch in batches:
        out.append([false])
    var check := func(batch: int) -> void:
        @warning_ignore("integer_division")
        var from := points.size() * batch / batches
        @warning_ignore("integer_division")
        var to := points.size() * (batch + 1) / batches
        out[batch][0] = CaveGround.run(data, func(): return CaveEntrance.roof_out(data, site, points, from, to))
    assert(_group < 0)
    _group = WorkerThreadPool.add_group_task(check, batches)
    while not WorkerThreadPool.is_group_task_completed(_group):
        await get_tree().process_frame
    WorkerThreadPool.wait_for_group_task_completion(_group)
    _group = -1
    for result: Array in out:
        if result[0]:
            return CaveEntrance.ROOF_OUT_ERROR
    if site.profile.entrance_type == "shaft":
        return ""
    var porch := await _run_cpu(func(): return {"error": CavePortal.porch_error(data, site)}, data)
    return str(porch.error)


## Same CPU-only contract as native terrain workers. Caller acquires tiles first. With [param data], the job's
## ground reads on that planet go through the native sampler (CaveGround).
func _run_cpu(job: Callable, data: PlanetData = null) -> Dictionary:
    assert(_task < 0)
    _result = [{}]
    var scoped := job if data == null else func(): return CaveGround.run(data, job)
    _task = WorkerThreadPool.add_task(func(): _result[0] = scoped.call())
    while not WorkerThreadPool.is_task_completed(_task):
        await get_tree().process_frame
    WorkerThreadPool.wait_for_task_completion(_task)
    _task = -1
    return _result[0]


func _wait_tiles(data: PlanetData, site: CavePlacement, survey: bool = false) -> bool:
    var deadline := Time.get_ticks_msec() + 15000
    var tiles := CavePlanetRegistry.site_tiles(data, site)
    if survey:
        CavePlanetRegistry._collect_tiles(data, site.surface_transform(), -80, 80, 80, tiles)
    while not CavePlanetRegistry.request_tiles(data, tiles):
        if cancelled or Time.get_ticks_msec() > deadline:
            return false
        await get_tree().create_timer(0.05).timeout
    return not cancelled


static func _reject(rejected: Dictionary, reason: String) -> void:
    rejected[reason] = int(rejected.get(reason, 0)) + 1


static func apply_family(profile: CaveProfile, biome: String) -> void:
    var family := "ice" if "ice" in biome or "glaci" in biome or "snow" in biome else \
        ("sand" if "desert" in biome or "sand" in biome else "rock")
    profile.profile_id = family
    profile.display_name = {"ice": "Glace", "sand": "Sable", "rock": "Roche"}[family]
    if profile.asset_library == null or profile.asset_library.surface_family != family:
        profile.asset_library = CaveAssetLibrary.default_for(family, true)


static func topography(data: PlanetData, site: CavePlacement) -> Dictionary:
    site = site.duplicate(true)
    site.heading_deg = 0.0
    var east := CaveEntrance.ground_point(data, site, 40, 0).y - CaveEntrance.ground_point(data, site, -40, 0).y
    var north := CaveEntrance.ground_point(data, site, 0, 40).y - CaveEntrance.ground_point(data, site, 0, -40).y
    var slope := Vector2(east, north).length() / 80.0
    var heading := rad_to_deg(atan2(east, north))
    # A rising slope that steepens uphill is a plausible footslope; no inferred geology/biome from colour.
    var forward := Vector2(sin(deg_to_rad(heading)), cos(deg_to_rad(heading)))
    var near_height := CaveEntrance.ground_point(data, site, forward.x * 40, forward.y * 40).y
    var far_height := CaveEntrance.ground_point(data, site, forward.x * 80, forward.y * 80).y
    var footslope := slope >= 0.03 and slope < 0.35 and far_height - near_height > slope * 40.0 + 1.0
    var label := "relief doux" if slope < 0.03 else ("pied de pente" if footslope else "versant")
    return {"heading": heading, "slope": slope, "label": label}


static func excluded_by_poi(site: CavePlacement, pois: Array[Dictionary]) -> bool:
    var direction := site.surface_direction()
    var reach := site.profile.length_m
    for opening in site.openings():
        reach = maxf(reach, float(opening.length) + (site.profile.length_m if not opening.primary else 0))
    for poi in pois:
        var clearance := float(poi.get("radius_m", 0)) + reach + 300.0
        if direction.distance_to(poi.dir) * site.planet_radius_m < clearance:
            return true
    return false
