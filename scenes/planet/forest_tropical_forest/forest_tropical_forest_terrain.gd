@tool
class_name ForestTropicalForestTerrain
## Terrain module for the **forest-tropical_forest** biome.
##
## A high-density vegetation ecosystem characterized by a closed canopy
## and multiple vegetation layers. Humidity is saturated.
## Category: terrestrial.  Layer group: individual (polygon).
## Includes default vegetation density and tree-type constants
## used by PlanetVegetation when no per-feature override exists.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "forest-tropical_forest"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 13
## Category tag for grouping.
const CATEGORY := "terrestrial"
## Default vegetation density when the QGIS feature has no override.
const DEFAULT_VEGETATION_DENSITY := 0.9
## Default tree type for VegetationRule matching.
const DEFAULT_TREE_TYPE := "tropical"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a forest-tropical_forest.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
