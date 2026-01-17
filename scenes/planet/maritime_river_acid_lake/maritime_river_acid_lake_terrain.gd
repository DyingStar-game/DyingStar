@tool
class_name MaritimeRiverAcidLakeTerrain
## Terrain module for the **maritime_river-acid_lake** liquid biome.
##
## Basins filled with a mixture of water and strong acids (sulfuric or hydrochloric), often located near volcanic areas.
## Category: toxic.  Layer group: individual (1 layer = 1 biome).
## Includes a default depth constant used by PlanetChunk when the
## QGIS feature has no explicit depth value.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "maritime_river-acid_lake"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 65
## Category tag for grouping.
const CATEGORY := "toxic"
## Default liquid depth when the QGIS feature has no depth value (metres).
const DEFAULT_DEPTH_M := 25.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a maritime_river-acid_lake.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
