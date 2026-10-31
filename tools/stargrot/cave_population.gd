class_name CavePopulation
extends CaveFitter
## Batch authoring only. All proposals are validated against native terrain before publication.
## Cancellation discards the staged batch; existing sites are never mutated.
## The fit itself (prepare_site, refit) is CaveFitter's, shared with the game.


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
