@tool
class_name MeadowSteppeTerraformedGrassTerrain
## Terrain module for the **meadow_steppe-terraformed_grass** vegetation biome.
##
## Artificial grassland ecosystem whose parameters have been modified to match
## a specific biological standard.
## Category: artificial.  Layer group: individual (polygon).
## Includes default vegetation density and tree-type constants
## used by PlanetVegetation when no per-feature override exists.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "meadow_steppe-terraformed_grass"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 77
## Category tag for grouping.
const CATEGORY := "artificial"
## Default vegetation density when the QGIS feature has no override.
const DEFAULT_VEGETATION_DENSITY := 0.5
## Default tree type for VegetationRule matching.
const DEFAULT_TREE_TYPE := "grass"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a meadow_steppe-terraformed_grass.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
