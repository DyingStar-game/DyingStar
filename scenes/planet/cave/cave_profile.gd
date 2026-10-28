@tool
class_name CaveProfile
extends Resource
## Authored cave dimensions. Snapshot values before sending geometry work to a worker.

## Stable profile identifier used in snapshots and cache identity; keep it unique within a profile family.
@export var profile_id: String = "rock"
## Human-readable profile name shown in the authoring interface.
@export var display_name: String = "Roche"
## Generator version (8 or 9). Required on disk: zero rejects an unversioned definition instead of silently
## upgrading it.
@export var generator_version: int = 0
## Shared wall/floor materials and decoration rules; changing it replaces the cave dressing.
@export var asset_library: CaveAssetLibrary
@export_group("Network")
## Network extent along its heading (m); higher values spread chambers and galleries farther apart.
@export_range(80.0, 1000.0, 1.0) var length_m: float = 100.0
## Nominal gallery width (m); erosion varies it while preserving the minimum passage clearance.
@export_range(2.0, 80.0, 0.25) var tunnel_width_m: float = 5.0
## Nominal gallery height (m); higher values create taller passages and increase mesh cost.
@export_range(2.0, 60.0, 0.25) var tunnel_height_m: float = 4.5
## Authored chamber count; each pattern draws a few more or fewer around it.
@export_range(1, 12, 1) var chamber_count: int = 2
## Interior drop (m) the chambers spread over.
@export_range(0.0, 480.0, 0.5) var depth_m: float = 8.0
## Tiers the network descends through (1–4), at least 8 m apart.
@export_range(1, 4, 1) var level_count: int = 1
## Size scale of the largest chambers (m): most are a share of it, now and then a giant goes beyond.
@export_range(6.0, 320.0, 1.0) var chamber_width_m: float = 18.0
## Reference chamber height (m); higher values raise vaults and require deeper terrain cover.
@export_range(4.0, 160.0, 1.0) var chamber_height_m: float = 10.0
## Requested secondary branch count (0..8); higher values create more offshoots.
@export_range(0, 8, 1) var branch_count: int = 3
## Requested solid rock pillar count (0..12); higher values leave more obstacles in chambers.
@export_range(0, 12, 1) var pillar_count: int = 3
## Requested natural rock bridge count (0..3); higher values add more spans inside chambers.
@export_range(0, 3, 1) var bridge_count: int = 1
## Version 8 only: squeezes in a terminal run of very low passages. Version 9 has none.
@export_range(0, 4, 1) var crawl_count: int = 2
@export_group("Surface")
## Wall and floor relief strength (0..1); higher values make surfaces less smooth.
@export_range(0.0, 1.0, 0.05) var roughness: float = 0.4
## Gallery meander strength (0..1); higher values bend paths farther from the main heading.
@export_range(0.0, 1.0, 0.05) var bend: float = 0.5
@export_group("Openings")
## ramp: a porch on a slope or a cliff; shaft: a doline; hangar: a giant porch.
@export_enum("ramp", "shaft", "hangar") var entrance_type: String = "ramp"
## Mouth width (m); higher values create a broader opening and require more terrain clearance.
@export_range(0.5, 100.0, 0.1) var entrance_width_m: float = 5.0
## Mouth height (m); higher values create a taller porch or a deeper doline throat.
@export_range(0.5, 60.0, 0.1) var entrance_height_m: float = 4.5
## Whether the network has a second surface opening; enabling it also cuts and fits an exit.
@export var exit_open: bool = false
## Second opening width (m), used only with Exit Open; higher values widen that opening.
@export_range(1.2, 100.0, 0.1) var exit_width_m: float = 3.0
## Second opening height (m), used only with Exit Open; higher values raise that opening.
@export_range(2.0, 60.0, 0.1) var exit_height_m: float = 2.5
## Longest reach (m) of the exit's weathered bowl into the ground.
@export_range(6.0, 120.0, 1.0) var shaft_length_m: float = 16.0
@export_group("Version 8 network")
## Share of the cave floor (0..1) the generator aims to leave reachable on foot from the entrance. Higher =
## more galleries kept walkable; lower = more shafts, pits and perched openings barring the way. Each seed
## lands near, not exactly on, this value: the workbench shows the measured share.
@export_range(0.2, 0.95, 0.05) var walkable_target: float = 0.7
## Zero keeps the smooth historical outlines. New definitions opt into coherent seeded entrance erosion.
@export_range(0.0, 1.0, 0.05) var entrance_noise: float = 0.0
## Cave pattern, after real karst caves: "auto" lets each seed draw one. Branchwork (a trunk with tributaries),
## maze (fissures on a joint grid), anastomotic (braided low tubes), spongework (many small linked cavities),
## ramiform (big chambers with radiating branches), shafts (a cascade of pits). It sets chamber sizes and
## families, branching, loops and passage sections.
@export_enum("auto", "branchwork", "maze", "anastomotic", "spongework", "ramiform", "shafts") \
    var network_style: String = "auto"
@export_group("Version 9 erosion and light")
## Seeded erosion of the galleries (0..1): narrowings and swellings along the way, an off-centre section,
## dissolution bells in the roof and stronger wall relief. The floor stays continuous to keep it walkable.
@export_range(0.0, 1.0, 0.05) var gallery_noise: float = 0.6
## Most natural light shafts (0..4) rising from chamber vaults to the ground. The seed places them where a
## column of rock above a chamber is free; each one opens a small hole in the terrain.
@export_range(0, 4, 1) var light_shafts: int = 1


## Plain values only: neither nodes nor mutable resources enter the geometry worker.
func snapshot(cave_seed: int) -> Dictionary:
    var spec := {
        "version": generator_version, "profile_id": profile_id, "seed": cave_seed,
        "length_m": length_m, "width_m": tunnel_width_m, "height_m": tunnel_height_m,
        "chambers": chamber_count, "depth_m": depth_m, "roughness": roughness, "bend": bend,
        "entrance_type": entrance_type, "entrance_width_m": entrance_width_m,
        "entrance_height_m": entrance_height_m, "shaft_length_m": shaft_length_m,
        "chamber_width_m": chamber_width_m, "chamber_height_m": chamber_height_m,
        "exit_open": exit_open, "exit_width_m": exit_width_m, "exit_height_m": exit_height_m,
        "levels": level_count, "branches": branch_count, "pillars": pillar_count,
        "bridges": bridge_count, "crawls": crawl_count,
        "walkable_target": walkable_target, "network_style": network_style,
    }
    if entrance_noise != 0.0:
        spec["entrance_noise"] = entrance_noise
    if generator_version >= 9:
        spec.merge({"gallery_noise": gallery_noise, "light_shafts": light_shafts})
    # Resource text serialization must not change geometry/cache identity.
    for key in spec:
        if spec[key] is float and is_finite(spec[key]):
            spec[key] = float("%.9f" % spec[key])
    return spec
