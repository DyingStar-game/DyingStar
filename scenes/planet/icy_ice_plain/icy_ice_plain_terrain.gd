@tool
class_name IcyIcePlainTerrain
## Terrain module for the **icy-ice_plain** biome.
##
## A flat expanse of massive ice. The albedo is very high, resulting in almost total reflection of stellar radiation.
## Category: cryo.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "icy-ice_plain"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 43
## Category tag for grouping.
const CATEGORY := "cryo"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is an icy-ice_plain.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
