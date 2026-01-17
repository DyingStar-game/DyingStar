@tool
class_name VolcanicGeothermalLavaFieldTerrain
## Terrain module for the **volcanic_geothermal-lava_field** biome.
##
## Extent of solidified lava exhibiting varied surface morphologies.
## Category: volcanic.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "volcanic_geothermal-lava_field"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 28
## Category tag for grouping.
const CATEGORY := "volcanic"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a volcanic_geothermal-lava_field.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
