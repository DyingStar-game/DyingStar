@tool
class_name RockyLandformMiningCaveTerrain
## Terrain module for the **rocky_landform-mining_cave** biome.
##
## An artificial or natural cavity modified for mineral extraction.
## Category: artificial.  Layer group: individual (point).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "rocky_landform-mining_cave"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 87
## Category tag for grouping.
const CATEGORY := "artificial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a rocky_landform-mining_cave.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
