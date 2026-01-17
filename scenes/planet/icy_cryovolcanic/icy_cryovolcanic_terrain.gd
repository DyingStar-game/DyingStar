@tool
class_name IcyCryovolcanicTerrain
## Terrain module for the **icy-cryovolcanic** biome.
##
## Cryovolcanic formation with volatile eruptions.
## Category: cryo.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "icy-cryovolcanic"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 49
## Category tag for grouping.
const CATEGORY := "cryo"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is an icy-cryovolcanic.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
