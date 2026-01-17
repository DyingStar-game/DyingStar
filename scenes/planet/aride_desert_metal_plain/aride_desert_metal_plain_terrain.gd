@tool
class_name ArideDesertMetalPlainTerrain
## Terrain module for the **aride_desert-metal_plain** biome.
##
## A biome whose surface is composed of native metals or minerals with a metallic luster.
## Category: mineral.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "aride_desert-metal_plain"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 72
## Category tag for grouping.
const CATEGORY := "mineral"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a aride_desert-metal_plain.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
