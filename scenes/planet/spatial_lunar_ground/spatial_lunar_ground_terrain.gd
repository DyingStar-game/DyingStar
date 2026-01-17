@tool
class_name SpatialLunarGroundTerrain
## Terrain module for the **spatial-lunar_ground** biome.
##
## Loose dusty surface with heavily cratered bright terrain, lunar regolith covering.
## Category: barren.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "spatial-lunar_ground"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 38
## Category tag for grouping.
const CATEGORY := "barren"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a spatial-lunar_ground.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
