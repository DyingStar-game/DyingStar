@tool
class_name IcyIcePickTerrain
## Terrain module for the **icy-ice_pick** biome.
##
## The formation of ice and hardened snow blades or needles from sublimation.
## Category: cryo.  Layer group: individual (line).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "icy-ice_pick"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 45
## Category tag for grouping.
const CATEGORY := "cryo"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is an icy-ice_pick.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
