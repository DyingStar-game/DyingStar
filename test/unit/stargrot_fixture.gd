extends RefCounted
## Shared StarGrotte test fixtures: current-version caves placed on a synthetic flat planet and fitted to it the
## way the workbench does. Not a suite itself (no test_ prefix).


class Flat extends PlanetData:
    func crack_aware_surface_dist(_direction: Vector3, _nside: int = -1, _spacing: float = 0.0) -> float:
        return radius


## A workbench preset without light shafts (they need a fit to be valid; tests opt in).
static func profile(size_index: int = 1) -> CaveProfile:
    var cave_profile := CaveWorkbench.preset(size_index)
    cave_profile.light_shafts = 0
    return cave_profile


static func placement(cave_profile: CaveProfile = null, cave_seed: int = 4242) -> CavePlacement:
    var site := CavePlacement.new()
    site.format_version = 2
    site.placement_id = "fixture"
    site.planet_name = "synthetic"
    site.terrain_version = "v"
    site.planet_radius_m = 6356000.0
    site.profile = cave_profile if cave_profile else profile()
    site.seed = cave_seed
    site.cover_m = 3.0
    return site


static func data(site: CavePlacement) -> PlanetData:
    var planet := Flat.new()
    planet.radius = site.planet_radius_m
    planet.planet_name = site.planet_name
    planet.chunk_data_version = site.terrain_version
    return planet


## Builds the cave and fits its entrance to the flat ground, as the workbench does; returns the cave.
static func fit(site: CavePlacement, planet: PlanetData) -> Dictionary:
    var cave := CaveGenerator.build(site.profile.snapshot(site.seed))
    if str(cave.error).is_empty():
        site.apply_fit(CavePortal.fit(planet, site, cave))
    return cave
