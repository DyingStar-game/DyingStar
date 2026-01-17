@tool
class_name VolcanicGeothermalVolcanicBasaltTerrain
## Terrain module for the **volcanic_geothermal-volcanic_basalt** biome.
##
## A plain of dense, dark, extrusive igneous rock. Rapid surface cooling
## creates a fine-grained rock, often structured into vast plateaus.
## Category: volcanic.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "volcanic_geothermal-volcanic_basalt"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 27
## Category tag for grouping.
const CATEGORY := "volcanic"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a volcanic_geothermal-volcanic_basalt.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
