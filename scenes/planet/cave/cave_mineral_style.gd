@tool
class_name CaveMineralStyle
extends Resource
## How a cave shows the rock it is dug in (CaveMineral): the tint its walls take, the material of its
## clear crystals and the soft lights their fluorescence throws. One per asset library; a library without
## one (ice, sand) keeps its walls as authored and grows no crystals.

@export_group("Walls")
## How far the cave walls, floor and rocks are tinted toward the rock's colour (0..1): 0 keeps the authored
## stone, 1 paints them the rock's colour outright.
@export_range(0.0, 1.0, 0.01) var wall_tint_strength: float = 0.45
## Screen-space subsurface scattering of the tinted walls (0..1), the milky depth of a translucent stone.
## Costs GPU time on every wall pixel: keep it low, 0 disables it (the soft wrapped lighting stays).
@export_range(0.0, 1.0, 0.01) var wall_subsurface: float = 0.15
## Milky corundum material of the cave walls (cave_corundum_rock.gdshader: a white, half translucent crystal);
## null keeps the library's own wall material, tinted. Its milk, clouds and bands are tuned in the material.
@export var translucent_wall_material: Material
## Milky corundum material of the cave floor, as for the walls; null keeps the library's floor, tinted.
@export var translucent_floor_material: Material
## Milky corundum material of the cave's rocks and formations (boulders, stalagmites…), as for the walls;
## null keeps their imported material, tinted. The crystals keep their own material.
@export var translucent_decor_material: Material

@export_group("Crystals")
## Material of the crystals, refracting what lies behind them (reads the screen texture).
@export var crystal_material: Material
## Cheaper opaque crystal material used when the ground quality setting is low (no screen copy).
@export var crystal_material_low: Material
## Rock (rocks.json slug) whose colour and fluorescence the crystals of a cave dug in another rock take: cave rock
## -> crystal rock. For the colourless corundums (milky, white), whose own crystals would be as pale as their
## walls: they grow rubies. A rock not listed keeps crystals of its own colour; the walls always keep theirs.
@export var crystal_rock_overrides: Dictionary[String, String] = {}

@export_group("Glow lights")
## Most fluorescence lights per cave (0..16): each lights the walls around a crystal cluster in its glow
## colour. 0 = crystals glow on their own but light nothing. Each one costs GPU time on the pixels it reaches.
@export_range(0, 16, 1) var glow_light_count: int = 4
## Energy of a glow light at full fluorescence strength (the rock's strength scales it): higher = brighter walls.
@export_range(0.0, 8.0, 0.05) var glow_light_energy: float = 1.0
## Reach of a glow light (m): larger lights more of the chamber around the cluster, at a higher GPU cost.
@export_range(1.0, 30.0, 0.5) var glow_light_range_m: float = 8.0
## Smallest distance between two glow lights (m): lower packs them on the first clusters, higher spreads them
## through the cave.
@export_range(1.0, 60.0, 0.5) var glow_light_spacing_m: float = 12.0
## Distance from the camera (m) where a glow light starts fading out; it is gone 10 m further.
@export_range(5.0, 200.0, 1.0) var glow_light_fade_begin_m: float = 30.0
## Rocks glowing weaker than this (0..1 fluorescence strength) get no glow light at all (blue, green caves).
@export_range(0.0, 1.0, 0.01) var glow_light_min_strength: float = 0.05
