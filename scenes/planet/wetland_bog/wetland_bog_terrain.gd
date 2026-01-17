@tool
class_name WetlandBogTerrain
## Terrain module for the **wetland-bog** biome.
##
## A wet, acidic ecosystem that accumulates undecomposed organic matter (peat).
## Growth is dominated by sphagnum mosses, creating a spongy soil capable of
## trapping significant amounts of carbon.
## Category: terrestrial.  Layer group: individual (polygon).
## Includes default vegetation density and tree-type constants
## used by PlanetVegetation when no per-feature override exists.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "wetland-bog"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 18
## Category tag for grouping.
const CATEGORY := "terrestrial"
## Default vegetation density when the QGIS feature has no override.
const DEFAULT_VEGETATION_DENSITY := 0.3
## Default tree type for VegetationRule matching.
const DEFAULT_TREE_TYPE := "moss"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a wetland-bog.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
