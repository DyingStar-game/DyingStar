@tool
class_name WetlandMangroveTerrain
## Terrain module for the **wetland-mangrove** biome.
##
## An amphibious coastal forest located in tropical zones.
## The trees have roots adapted to high salinity and muddy soil.
## Category: terrestrial.  Layer group: individual (polygon).
## Includes default vegetation density and tree-type constants
## used by PlanetVegetation when no per-feature override exists.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "wetland-mangrove"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 17
## Category tag for grouping.
const CATEGORY := "terrestrial"
## Default vegetation density when the QGIS feature has no override.
const DEFAULT_VEGETATION_DENSITY := 0.6
## Default tree type for VegetationRule matching.
const DEFAULT_TREE_TYPE := "mangrove"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a wetland-mangrove.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
