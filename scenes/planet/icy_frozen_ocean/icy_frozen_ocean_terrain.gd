@tool
class_name IcyFrozenOceanTerrain
## Terrain module for the **icy-frozen_ocean** biome.
##
## A thick ice pack of water ice overlying a liquid ocean maintained by
## tidal heating or thermal insulation.
## Category: cryo.  Layer group: individual (polygon).
## Includes a default depth constant used by PlanetChunk when the
## QGIS feature has no explicit depth value.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "icy-frozen_ocean"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 50
## Category tag for grouping.
const CATEGORY := "cryo"
## Default liquid depth when the QGIS feature has no depth value (metres).
const DEFAULT_DEPTH_M := 80.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is an icy-frozen_ocean.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
