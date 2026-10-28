class_name CavePopulation
extends Node
## Batch authoring only. All proposals are validated against native terrain before publication.
## Cancellation discards the staged batch; existing sites are never mutated.

signal progress(accepted: int, requested: int, attempted: int, message: String)

var cancelled: bool = false
var _task: int = -1
var _result: Array = [{}]


func _exit_tree() -> void:
    if _task >= 0:
        WorkerThreadPool.wait_for_task_completion(_task)


func generate(data: PlanetData, existing: Array[CavePlacement], requested: int, batch_seed: int) -> Dictionary:
    cancelled = false
    if not CaveNetwork.warm():
        return {"sites": [], "error": "Le module de géométrie doit être compilé.", "rejected": {}}
    if existing.size() >= CavePlanetRegistry.MAX_TRIAL_SITES:
        return {"sites": [], "error": "Cette planète contient déjà 512 sites.", "rejected": {}}
    requested = clampi(requested, 1, CavePlanetRegistry.MAX_TRIAL_SITES - existing.size())
    var rng := RandomNumberGenerator.new()
    rng.seed = batch_seed
    var accepted: Array[CavePlacement] = []
    var bounds: Array[AABB] = []
    var ids: Dictionary = {}
    for site in existing:
        bounds.append(site.footprint_bounds())
        ids[site.placement_id] = true
    var mountain_edges := mountain_candidates(data)
    var pois := StarMapPoi.load_for(data.planet_name)
    var rejected: Dictionary = {}
    var missing_tiles := 0
    var attempts := requested * 10
    var queue: Array[CavePlacement] = []
    for index in attempts:
        var lonlat := Vector2(rng.randf_range(-180.0, 180.0), rad_to_deg(asin(rng.randf_range(-1.0, 1.0))))
        if not mountain_edges.is_empty() and index % 2 == 0:
            lonlat = mountain_edges[rng.randi_range(0, mountain_edges.size() - 1)]
            var degrees := rad_to_deg(rng.randf_range(20.0, 180.0) / data.radius)
            lonlat += Vector2(degrees / maxf(0.15, cos(deg_to_rad(lonlat.y))), degrees) * (1 if index % 4 == 0 else -1)
            lonlat.x = wrapf(lonlat.x, -180, 180)
            lonlat.y = clampf(lonlat.y, -89, 89)
        queue.append(proposal(data, lonlat, batch_seed, index, rng))
    for index in queue.size():
        if cancelled or accepted.size() >= requested:
            break
        var site := queue[index]
        if ids.has(site.placement_id):
            _reject(rejected, "Identifiant déjà présent")
            continue
        # Bound native tile requests; all placement paths share prepare_site below.
        for ahead in range(index, mini(queue.size(), index + 6)):
            CavePlanetRegistry.tiles_ready(data, queue[ahead])
        progress.emit(accepted.size(), requested, index + 1, "Lecture du relief et vérification du site…")
        var prepared := await prepare_site(data, site, true, pois)
        var error := str(prepared.error)
        if not error.is_empty():
            _reject(rejected, error)
            missing_tiles = missing_tiles + 1 if "Tuiles" in error else 0
            if missing_tiles >= 8:
                break
            continue
        missing_tiles = 0
        site.resource_name = "Grotte %03d · %s" % [existing.size() + accepted.size() + 1, prepared.relief.label]
        var footprint := site.footprint_bounds()
        var overlaps := false
        for previous in bounds:
            if footprint.intersects(previous):
                overlaps = true
                break
        if overlaps:
            _reject(rejected, "Autre grotte trop proche")
            continue
        if cancelled:
            break
        accepted.append(site)
        bounds.append(footprint)
        ids[site.placement_id] = true
        progress.emit(accepted.size(), requested, index + 1, "Site validé automatiquement")
        await get_tree().process_frame
    if cancelled:
        accepted.clear()
    return {"sites": accepted, "rejected": rejected, "cancelled": cancelled,
        "error": "Tuiles indisponibles : génération interrompue." if missing_tiles >= 8 else "",
        "requested": requested, "seed": batch_seed}


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
        var result := await _run_cpu(func(): return CavePortal.fit(data, site, cave))
        if not str(result.error).is_empty():
            return str(result.error)
        site.apply_fit(result)
        if not await _wait_tiles(data, site):
            return "Tuiles du réseau ajusté indisponibles"
    return ""


func entrance_error(data: PlanetData, site: CavePlacement, cave: Dictionary) -> String:
    var result := await _run_cpu(func(): return {"error": CaveEntrance.site_error(data, site, cave)})
    return str(result.error)


## Same CPU-only contract as native terrain workers. Caller acquires tiles first.
func _run_cpu(job: Callable) -> Dictionary:
    assert(_task < 0)
    _result = [{}]
    _task = WorkerThreadPool.add_task(func(): _result[0] = job.call())
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


static func proposal(data: PlanetData, lonlat: Vector2, batch_seed: int, index: int, rng: RandomNumberGenerator) -> CavePlacement:
    var site := CavePlacement.new()
    site.format_version = 2
    site.placement_id = "auto-%s-%d-%d" % [data.planet_name, batch_seed, index]
    site.planet_name = data.planet_name
    site.planet_radius_m = data.radius
    site.terrain_version = data.chunk_data_version
    site.longitude_deg = lonlat.x
    site.latitude_deg = lonlat.y
    site.seed = rng.randi_range(0, 2147483647)
    var profile := CaveProfile.new()
    profile.generator_version = CaveGenerator.VERSION
    profile.length_m = rng.randi_range(100, 190)
    profile.tunnel_width_m = rng.randf_range(5.0, 8.0)
    profile.tunnel_height_m = rng.randf_range(3.5, 5.5)
    profile.chamber_width_m = rng.randf_range(14.0, 32.0)
    profile.chamber_height_m = rng.randf_range(6.0, 14.0)
    profile.level_count = 1 + (index % 3)
    profile.chamber_count = rng.randi_range(3, 7)
    profile.branch_count = rng.randi_range(1, 5)
    profile.pillar_count = rng.randi_range(1, 6)
    profile.bridge_count = rng.randi_range(0, 2)
    if index % 13 == 0:
        profile.length_m = rng.randi_range(280, 440)
        profile.tunnel_width_m = rng.randf_range(8, 12)
        profile.tunnel_height_m = rng.randf_range(6, 9)
        profile.chamber_width_m = rng.randf_range(100, 170)
        profile.chamber_height_m = rng.randf_range(35, 65)
        profile.level_count = 1
        profile.bridge_count = 1
    profile.depth_m = ceil((profile.chamber_height_m + 5.0) * (profile.level_count - 1) * 1000.0) / 1000.0
    profile.roughness = rng.randf_range(0.3, 0.9)
    profile.entrance_noise = 0.55
    profile.gallery_noise = snappedf(rng.randf_range(0.35, 0.85), 0.05)
    # Now and then a light shaft or two opens a chamber's vault to the sky.
    profile.light_shafts = 0 if rng.randf() < 0.45 else rng.randi_range(1, 2)
    profile.bend = rng.randf_range(0.2, 1.0)
    profile.entrance_width_m = rng.randf_range(profile.tunnel_width_m, profile.chamber_width_m * 0.8)
    profile.entrance_height_m = rng.randf_range(2.6, profile.tunnel_height_m)
    profile.entrance_type = "hangar" if index % 7 == 0 else "ramp"
    if profile.entrance_type == "hangar":
        profile.entrance_width_m = minf(100.0, profile.chamber_width_m * 0.7)
        profile.entrance_height_m = profile.chamber_height_m * 0.7
    profile.exit_open = index % 4 == 0
    profile.exit_width_m = maxf(4.0, profile.tunnel_width_m * 0.8)
    profile.exit_height_m = 3.0
    site.profile = profile
    site.cover_m = 3.0
    site.ramp_length_m = 20.0
    apply_family(profile, "")
    return site


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


static func mountain_candidates(data: PlanetData) -> Array[Vector2]:
    var points: Array[Vector2] = []
    var seen: Dictionary = {}
    for face in 12:
        for zone in data.get_chunk_mountain_zones(1, face):
            for edge in zone.polygon.size():
                var point: Vector2 = zone.polygon[edge]
                var key := Vector2(snappedf(point.x, 0.0001), snappedf(point.y, 0.0001))
                if not seen.has(key):
                    seen[key] = true
                    points.append(point)
                    # Include edge interiors, not just the vertices of native mountain outlines.
                    var next: Vector2 = zone.polygon[(edge + 1) % zone.polygon.size()]
                    if absf(point.x - next.x) < 180:
                        for fraction in [0.25, 0.5, 0.75]:
                            points.append(point.lerp(next, fraction))
    return points


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


static func accessible_entry_error(cave: Dictionary) -> String:
    if cave.graph.has("sky"):
        return ""  # a doline is entered from above: no gallery leads to its chamber
    # Guarantee passage to the first room; dead ends and difficult deeper branches remain intentional.
    for link: Dictionary in cave.graph.links.slice(0, 2):
        var points: Array = link.points
        for segment in points.size() - 1:
            for step in 6:
                var p: Vector3 = points[segment].lerp(points[segment + 1], float(step) / 5.0)
                for offset in [Vector3(0, 1.9, 0), Vector3(0.4, 1.0, 0), Vector3(-0.4, 1.0, 0)]:
                    if float(cave.sampler.call("Sample", p + offset)) < 0.1:
                        return "Premier passage trop étroit pour la capsule."
    return ""
