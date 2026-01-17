@tool
class_name RadioactiveWasteTerrain
## Terrain module for the **radioactive_waste** biome.
##
## Irradiated contaminated zone.
## Category: toxic.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "radioactive_waste"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 68
## Category tag for grouping.
const CATEGORY := "toxic"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a radioactive_waste.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
