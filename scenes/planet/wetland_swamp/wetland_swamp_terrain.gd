@tool
class_name WetlandSwampTerrain
## Terrain module for the **wetland-swamp** biome.
##
## A wooded or grassy wetland where stagnant water permanently saturates the soil.
## Characterized by fine sedimentation and high bacterial activity.
## Category: terrestrial.  Layer group: individual (polygon).
## Includes default vegetation density and tree-type constants
## used by PlanetVegetation when no per-feature override exists.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "wetland-swamp"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 16
## Category tag for grouping.
const CATEGORY := "terrestrial"
## Default vegetation density when the QGIS feature has no override.
const DEFAULT_VEGETATION_DENSITY := 0.4
## Default tree type for VegetationRule matching.
const DEFAULT_TREE_TYPE := "marsh"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a wetland-swamp.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
