@tool
class_name IcyMethaneLakeTerrain
## Terrain module for the **icy-methane_lake** biome.
##
## A liquid basin of light hydrocarbons (methane/ethane).
## Category: cryo.  Layer group: individual (polygon).
## Includes a default depth constant used by PlanetChunk when the
## QGIS feature has no explicit depth value.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "icy-methane_lake"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 47
## Category tag for grouping.
const CATEGORY := "cryo"
## Default liquid depth when the QGIS feature has no depth value (metres).
const DEFAULT_DEPTH_M := 40.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is an icy-methane_lake.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
