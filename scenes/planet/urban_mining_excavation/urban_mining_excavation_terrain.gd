@tool
class_name UrbanMiningExcavationTerrain
## Terrain module for the **urban-mining_excavation** biome.
##
## Open-pit industrial excavation for mineral resource extraction. Features a stepped topography.
## Category: artificial.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "urban-mining_excavation"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 79
## Category tag for grouping.
const CATEGORY := "artificial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a urban-mining_excavation.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
