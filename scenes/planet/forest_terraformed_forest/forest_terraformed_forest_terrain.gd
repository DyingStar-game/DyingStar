@tool
class_name ForestTerraformedForestTerrain
## Terrain module for the **forest-terraformed_forest** biome.
##
## Artificial planted forest cover on previously treated soil.
## Category: artificial.  Layer group: individual (polygon).
## Includes default vegetation density and tree-type constants
## used by PlanetVegetation when no per-feature override exists.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "forest-terraformed_forest"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 78
## Category tag for grouping.
const CATEGORY := "artificial"
## Default vegetation density when the QGIS feature has no override.
const DEFAULT_VEGETATION_DENSITY := 0.7
## Default tree type for VegetationRule matching.
const DEFAULT_TREE_TYPE := "deciduous"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a forest-terraformed_forest.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
