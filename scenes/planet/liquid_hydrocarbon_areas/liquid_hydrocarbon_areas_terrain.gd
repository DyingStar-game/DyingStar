@tool
class_name LiquidHydrocarbonAreasTerrain
## Terrain module for the **liquid_hydrocarbon_areas** biome.
##
## Surface liquid at extreme pressure/temperature.
## Category: atmosphere.  Layer group: individual (polygon).
## Includes a default depth constant used by PlanetChunk when the
## QGIS feature has no explicit depth value.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "liquid_hydrocarbon_areas"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 62
## Category tag for grouping.
const CATEGORY := "atmosphere"
## Default liquid depth when the QGIS feature has no depth value (metres).
const DEFAULT_DEPTH_M := 60.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a liquid_hydrocarbon_areas.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
