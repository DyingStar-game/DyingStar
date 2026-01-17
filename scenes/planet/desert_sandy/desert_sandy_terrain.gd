@tool
class_name DesertSandyTerrain
## Terrain module for the **aride_desert-sandy_desert** biome.
##
## A hyperarid region dominated by the accumulation of quartz or silicate grains.
## Category: terrestrial.  Layer group: individual.
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "aride_desert-sandy_desert"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 5
## Category tag for grouping.
const CATEGORY := "terrestrial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a aride_desert-sandy_desert.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
