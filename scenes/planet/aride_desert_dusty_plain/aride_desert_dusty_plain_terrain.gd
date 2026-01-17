@tool
class_name ArideDesertDustyPlainTerrain
## Terrain module for the **aride_desert-dusty_plain** biome.
##
## Low-lying area covered with very fine particles (silt, clay). Susceptible to dust storms.
## Category: barren.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "aride_desert-dusty_plain"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 42
## Category tag for grouping.
const CATEGORY := "barren"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is an aride_desert-dusty_plain.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
