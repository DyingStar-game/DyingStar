@tool
class_name VolcanicGeothermalAshDesertTerrain
## Terrain module for the **volcanic_geothermal-ash_desert** biome.
##
## A thick layer of ash deposited after an explosive eruption.
## Category: volcanic.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "volcanic_geothermal-ash_desert"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 33
## Category tag for grouping.
const CATEGORY := "volcanic"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a volcanic_geothermal-ash_desert.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
