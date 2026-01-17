@tool
class_name WetlandAmmoniaSwampTerrain
## Terrain module for the **wetland-ammonia_swamp** liquid biome.
##
## Humid areas where the main solvent is not pure water but a water-ammonia mixture.
## The ammonia acts as an antifreeze, allowing the liquid to exist at temperatures well below 0°C.
## Category: toxic.  Layer group: individual (1 layer = 1 biome).
## Includes a default depth constant used by PlanetChunk when the
## QGIS feature has no explicit depth value.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "wetland-ammonia_swamp"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 66
## Category tag for grouping.
const CATEGORY := "toxic"
## Default liquid depth when the QGIS feature has no depth value (metres).
const DEFAULT_DEPTH_M := 8.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a wetland-ammonia_swamp.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
