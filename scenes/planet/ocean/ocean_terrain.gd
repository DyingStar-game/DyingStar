@tool
class_name OceanTerrain
## Terrain module for the **maritime_river-ocean** liquid biome.
##
## A vast expanse of liquid water subject to natural currents.
## Category: terrestrial.  Layer: individual (polygon).
## Includes a default depth constant used by PlanetChunk when the
## QGIS feature has no explicit depth value.

# ── Constants ──────────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "maritime_river-ocean"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 0
## Category tag for grouping.
const CATEGORY := "terrestrial"
## Default liquid depth when the QGIS feature has no depth value (metres).
const DEFAULT_DEPTH_M := 100.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a maritime_river-ocean.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
