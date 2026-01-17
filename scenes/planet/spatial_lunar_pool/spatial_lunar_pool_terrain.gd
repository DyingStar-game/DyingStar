@tool
class_name SpatialLunarPoolTerrain
## Terrain module for the **spatial-lunar_pool** biome.
##
## Vast plains of dark basalt occupying giant impact basins.
## Category: barren.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "spatial-lunar_pool"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 39
## Category tag for grouping.
const CATEGORY := "barren"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a spatial-lunar_pool.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
