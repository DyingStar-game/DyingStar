@tool
class_name RockyLandformRawMountainTerrain
## Terrain module for the **rocky_landform-raw_mountain** biome.
##
## A high-altitude summit or slope located above the lichen growth limit.
## The landscape is dominated by exposed bedrock.
## Category: terrestrial.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "rocky_landform-raw_mountain"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 22
## Category tag for grouping.
const CATEGORY := "terrestrial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a rocky_landform-raw_mountain.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
