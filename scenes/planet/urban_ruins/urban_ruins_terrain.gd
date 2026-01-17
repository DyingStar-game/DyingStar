@tool
class_name UrbanRuinsTerrain
## Terrain module for the **urban-ruins** biome.
##
## Urban or industrial complex in a state of advanced structural degradation.
## Category: artificial.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "urban-ruins"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 80
## Category tag for grouping.
const CATEGORY := "artificial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a urban-ruins.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
