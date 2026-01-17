@tool
class_name CrystallineCrystallineFieldsTerrain
## Terrain module for the **crystalline-crystalline_fields** biome.
##
## Areas covered with macro-crystals (quartz, selenite or fluorite).
## Category: mineral.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "crystalline-crystalline_fields"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 71
## Category tag for grouping.
const CATEGORY := "mineral"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a crystalline-crystalline_fields.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
