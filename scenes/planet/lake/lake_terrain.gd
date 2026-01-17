@tool
class_name LakeTerrain
## Terrain module for the **maritime_river-lake** liquid biome.
##
## A freshwater or saltwater basin, isolated from ocean currents.
## Category: terrestrial.  Layer: individual (polygon).
## Includes a default depth constant used by PlanetChunk when the
## QGIS feature has no explicit depth value.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "maritime_river-lake"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 2
## Category tag for grouping.
const CATEGORY := "terrestrial"
## Default liquid depth when the QGIS feature has no depth value (metres).
const DEFAULT_DEPTH_M := 30.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a maritime_river-lake.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
