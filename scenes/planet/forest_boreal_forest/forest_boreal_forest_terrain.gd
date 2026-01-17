@tool
class_name ForestBorealForestTerrain
## Terrain module for the **forest-boreal_forest** biome.
##
## A vast belt of conifers adapted to cold climates.
## The soil is acidic and species biodiversity is reduced.
## Category: terrestrial.  Layer group: individual (polygon).
## Includes default vegetation density and tree-type constants
## used by PlanetVegetation when no per-feature override exists.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "forest-boreal_forest"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 12
## Category tag for grouping.
const CATEGORY := "terrestrial"
## Default vegetation density when the QGIS feature has no override.
const DEFAULT_VEGETATION_DENSITY := 0.7
## Default tree type for VegetationRule matching.
const DEFAULT_TREE_TYPE := "conifer"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a boreal forest.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
