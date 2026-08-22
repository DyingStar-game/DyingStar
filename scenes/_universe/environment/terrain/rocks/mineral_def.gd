class_name MineralDef
extends Resource

## Full definition of a mineral that can appear in a mining rock.
##
## One `.tres` per mineral;

## Identifier (e.g. &"gold")
# Covers three concerns:
##   - Visual ORE look  (Albedo / Surface / Material groups) — the vein colour/texture inside
##   - Host Rock look   (Host Rock group) — the exterior surface of the rock carrying this ore
##   - Physical & game  (Physical / Trading / Identity groups) — density, hardness, trade value
##
## One `.tres` per mineral; add a new mineral = new `.tres` + one entry in MineralRegistry.
## The ore FIELD (amount, dispersion, persistence) stays on the rock itself so swapping
## minerals never changes fracture/purity behaviour.

@export_group("Identity")
## Identifier (e.g. &"gold"). Must match the key in MineralRegistry.ALL.
@export var id: StringName = &""
## Human-readable name shown in the UI (e.g. "Gold", "Cryptonite", "Basalt").
@export var display_name: String = ""
## When true, this mineral yields no ore: the depot will not accept it and the rock renders
## no ore veins (rock_mining.gd forces ore_threshold = 1.0 in the material).
@export var is_inert: bool = false

@export_group("Albedo")
## When true the ore is drawn with `albedo_tex` (triplanar, local space) instead of a flat color.
@export var use_texture: bool = false
@export var albedo_tex: Texture2D = null
## Tints the texture, or IS the ore color when `use_texture` is false.
@export var color: Color = Color(0.1, 0.8, 0.2)

@export_group("Surface")
@export var normal_tex: Texture2D = null
## Strength of the ore normal-map relief (0 = flat). Ignored when no `normal_tex`.
@export_range(0.0, 2.0) var normal_strength: float = 1.0
## Triplanar tiling of the ore textures (local space).
@export var tex_scale: float = 1.0

@export_group("Material")
@export_range(0.0, 1.0) var metallic: float = 1.0
@export_range(0.0, 1.0) var roughness: float = 0.14
## Self-illumination. 0 = realistic metal; >0 = glows (the old cryptonite preset used ~9).
@export var emission: float = 0.0

@export_group("Host Rock")
## The EXTERIOR of a mining rock, i.e. the barren gangue around the ore. Two different minerals
## can feed it: the rock's own mineral (a gold rock carries "what gold ore looks like from
## outside"), or — when the spawner replicated a `host_rock_id` — the inert mineral naming the
## local geology, which then wins. That second path is how a whole planet reads as one rock type;
## see MiningZone.host_rock_id / PlanetData.mining_zone_host_rock.
##
## Exterior surface texture of the host rock (triplanar, local space).
## When null, rock_mining.gd falls back to the built-in Rock029 texture.
@export var rock_albedo_tex: Texture2D = null
## Optional exterior normal map for the host rock surface. Only applied when this def is used as
## the HOST ROCK of a rock (not through the ore-mineral fallback), so an existing rock whose
## mineral happens to carry one does not silently change look.
@export var rock_normal_tex: Texture2D = null
## Relief strength of `rock_normal_tex` (0 = flat). Ignored when there is no exterior normal map.
@export_range(0.0, 2.0) var rock_normal_strength: float = 1.0
## Triplanar tiling scale for the host rock exterior.
@export var rock_tex_scale: float = 1.0
## Surface roughness of the barren exterior. 0.9 is the value the rock shader used for every rock
## before host rocks existed — keep it there unless the geology really is polished (corundum ~0.3).
@export_range(0.0, 1.0) var rock_roughness: float = 0.9

@export_group("Physical")
## Density in kg/m³ — used to derive RigidBody mass from rock volume.
## Typical values: sandstone 2200, granite/quartz 2700, basalt 2900, iron 7874, gold 19300.
@export var density_kg_m3: float = 2700.0
## Drill resistance (0 = soft clay, 1 = hardest diamond).
## Drives tool wear / break time. Not yet consumed — wired when the drill tool is built.
@export_range(0.0, 1.0) var hardness: float = 0.5

@export_group("Trading")
## Base trade value per cubic metre of ore (currency units).
## Multiplied by purity at the depot. Set to 0.0 for all inert minerals.
@export var base_value: float = 1.0

