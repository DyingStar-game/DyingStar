@tool
class_name TarBasinTerrain
## Terrain module for the **tar_basin** liquid biome.
##
## Depressions filled with heavy hydrocarbons (bitumen, asphalt).
## These basins are formidable natural traps.
## Category: toxic.  Layer group: individual (polygon).
## Includes a default depth constant used by PlanetChunk when the
## QGIS feature has no explicit depth value.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "tar_basin"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 69
## Category tag for grouping.
const CATEGORY := "toxic"
## Default liquid depth when the QGIS feature has no depth value (metres).
const DEFAULT_DEPTH_M := 15.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a tar_basin.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
