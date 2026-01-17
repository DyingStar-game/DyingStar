@tool
class_name BrineBasinTerrain
## Terrain module for the **brine_basin** liquid biome.
##
## Submarine or surface lakes with such high salinity that the liquid
## becomes much denser than the surrounding water. These areas are
## often devoid of oxygen.
## Category: toxic.  Layer group: individual (polygon).
## Includes a default depth constant used by PlanetChunk when the
## QGIS feature has no explicit depth value.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "brine_basin"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 70
## Category tag for grouping.
const CATEGORY := "toxic"
## Default liquid depth when the QGIS feature has no depth value (metres).
const DEFAULT_DEPTH_M := 20.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a brine_basin.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
