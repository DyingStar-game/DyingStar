@tool
class_name VolcanicGeothermalLavaLakeTerrain
## Terrain module for the **volcanic_geothermal-lava_lake** biome.
##
## A depression filled with liquid magma, kept molten by thermal convection.
## A semi-solid crust can form on the surface, constantly fractured by magma currents.
## Category: volcanic.  Layer group: individual (polygon).
## Includes a default depth constant used by PlanetChunk when the
## QGIS feature has no explicit depth value.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "volcanic_geothermal-lava_lake"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 29
## Category tag for grouping.
const CATEGORY := "volcanic"
## Default liquid depth when the QGIS feature has no depth value (metres).
const DEFAULT_DEPTH_M := 50.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a volcanic_geothermal-lava_lake.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
