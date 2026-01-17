@tool
class_name ArideDesertIronDesertTerrain
## Terrain module for the **aride_desert-iron_desert** biome.
##
## A biome whose characteristic red color comes from the oxidation of
## iron dust. The atmosphere there is often thin and rich in dust.
## Category: martian.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "aride_desert-iron_desert"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 54
## Category tag for grouping.
const CATEGORY := "martian"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is an aride_desert-iron_desert.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
