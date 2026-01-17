@tool
class_name MeadowSteppeAgricultureLandTerrain
## Terrain module for the **meadow_steppe-agriculture_land** vegetation biome.
##
## Industrial agricultural production zone. Characterized by a geometric sectorization of the land.
## Category: artificial.  Layer group: individual (polygon).
## Includes default vegetation density and tree-type constants
## used by PlanetVegetation when no per-feature override exists.

# ── Constants ────────────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "meadow_steppe-agriculture_land"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 82
## Category tag for grouping.
const CATEGORY := "artificial"
## Default vegetation density when the QGIS feature has no override.
const DEFAULT_VEGETATION_DENSITY := 0.8
## Default tree type for VegetationRule matching.
const DEFAULT_TREE_TYPE := "crop"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a meadow_steppe-agriculture_land.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
