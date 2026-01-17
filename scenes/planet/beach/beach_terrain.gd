@tool
class_name BeachTerrain
## Terrain module for the **maritime_river-beach** biome.
##
## Accumulation of loose sediments (sand, gravel, pebbles) along a coastline.
## Category: terrestrial.  Layer group: individual.
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "maritime_river-beach"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 4
## Category tag for grouping.
const CATEGORY := "terrestrial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a maritime_river-beach.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
