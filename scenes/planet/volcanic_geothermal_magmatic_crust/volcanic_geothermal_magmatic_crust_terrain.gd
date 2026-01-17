@tool
class_name VolcanicGeothermalMagmaticCrustTerrain
## Terrain module for the **volcanic_geothermal-magmatic_crust** biome.
##
## An unstable zone where a thin layer of solidified rock covers a shallow magma reservoir.
## Category: volcanic.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "volcanic_geothermal-magmatic_crust"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 34
## Category tag for grouping.
const CATEGORY := "volcanic"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a volcanic_geothermal-magmatic_crust.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
