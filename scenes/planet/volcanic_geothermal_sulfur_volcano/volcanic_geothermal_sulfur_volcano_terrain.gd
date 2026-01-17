@tool
class_name VolcanicGeothermalSulfurVolcanoTerrain
## Terrain module for the **volcanic_geothermal-sulfur_volcano** biome.
##
## Unlike terrestrial silicate volcanoes, these spew molten sulfur whose color
## changes according to the temperature (from yellow to black through blood red).
## Category: toxic.  Layer group: individual (1 layer = 1 biome).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "volcanic_geothermal-sulfur_volcano"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 64
## Category tag for grouping.
const CATEGORY := "toxic"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a volcanic_geothermal-sulfur_volcano.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
