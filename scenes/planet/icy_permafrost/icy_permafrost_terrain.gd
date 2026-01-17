@tool
class_name IcyPermafrostTerrain
## Terrain module for the **icy-permafrost** biome.
##
## Soil whose temperature remains below 0°C for years. Structured soils
## (frost polygons) are often found there, resulting from freeze-thaw cycles.
## Category: cryo.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "icy-permafrost"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 52
## Category tag for grouping.
const CATEGORY := "cryo"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is an icy-permafrost.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
