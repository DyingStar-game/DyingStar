@tool
class_name CrystallineQuartzDesertTerrain
## Terrain module for the **crystalline-quartz_desert** biome.
##
## Arid expanse composed of pure silica grains. Unlike classic silica sand, the surface has a vitreous and semi-translucent appearance.
## Category: mineral.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "crystalline-quartz_desert"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 74
## Category tag for grouping.
const CATEGORY := "mineral"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a crystalline-quartz_desert.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
