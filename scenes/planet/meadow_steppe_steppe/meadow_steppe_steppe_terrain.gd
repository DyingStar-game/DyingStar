@tool
class_name MeadowSteppeSteppeTerrain
## Terrain module for the **meadow_steppe-steppe** biome.
##
## Semi-arid plain covered with short grasses and shrubby plants,
## forming a transition zone between meadow and desert.
## Category: terrestrial.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "meadow_steppe-steppe"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 10
## Category tag for grouping.
const CATEGORY := "terrestrial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a steppe.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
