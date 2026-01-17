@tool
class_name DesertSaltTerrain
## Terrain module for the **aride_desert-salt_desert** biome.
##
## An endorheic depression where evaporation of runoff water leaves behind a crust of evaporites.
## Category: terrestrial.  Layer group: individual.
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "aride_desert-salt_desert"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 7
## Category tag for grouping.
const CATEGORY := "terrestrial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a aride_desert-salt_desert.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
