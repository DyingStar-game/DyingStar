@tool
class_name ForestDeadForestTerrain
## Terrain module for the **forest-dead_forest** biome.
##
## Tree stand that has lost its biological viability. The woody structures
## survive as charred or mineralized skeletons.
## Category: terrestrial.  Layer group: individual (polygon).
## Includes default vegetation density and tree-type constants
## used by PlanetVegetation when no per-feature override exists.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "forest-dead_forest"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 14
## Category tag for grouping.
const CATEGORY := "terrestrial"
## Default vegetation density when the QGIS feature has no override.
const DEFAULT_VEGETATION_DENSITY := 0.3
## Default tree type for VegetationRule matching.
const DEFAULT_TREE_TYPE := "dead"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a forest-dead_forest.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
