@tool
class_name RiverDeltaTerrain
## Terrain module for the **maritime_river-delta** liquid biome.
##
## Alluvial wetland at the river mouth.
## Category: terrestrial.  Layer: individual (polygon).
## Includes a default depth constant used by PlanetChunk when the
## QGIS feature has no explicit depth value.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "maritime_river-delta"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 3
## Category tag for grouping.
const CATEGORY := "terrestrial"
## Default liquid depth when the QGIS feature has no depth value (metres).
const DEFAULT_DEPTH_M := 5.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a maritime_river-delta.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
