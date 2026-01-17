@tool
class_name CrystallineSaltCrystalFieldTerrain
## Terrain module for the **crystalline-salt_crystal_field** biome.
##
## Massive sedimentary deposit of halites. The biome is characterized by natural
## cubic formations and hopper-like structures rising from the ground.
## Category: mineral.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "crystalline-salt_crystal_field"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 76
## Category tag for grouping.
const CATEGORY := "mineral"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a crystalline-salt_crystal_field.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
