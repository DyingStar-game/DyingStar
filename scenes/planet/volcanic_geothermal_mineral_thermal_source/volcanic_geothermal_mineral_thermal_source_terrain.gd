@tool
class_name VolcanicGeothermalMineralThermalSourceTerrain
## Self-contained constants and helpers for mineral thermal source terrain depressions.
##
## A hydrothermal water basin saturated with dissolved minerals.
## The cooling of the water at the surface leads to the formation of travertine
## terraces or siliceous frits. The basins are often vividly colored.
## All constants are local to this module — independent of other biomes.

# ── Constants ──────────────────────────────────────────────────────

## Radius of the terrain depression around the thermal source (metres).
const DEPRESSION_RADIUS_M := 25.0
## Depth of the depression at the pool centre (metres).
const DEPRESSION_DEPTH_M := 6.0
## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "volcanic_geothermal-mineral_thermal_source"


# ── Detection helpers ──────────────────────────────────────────────

## Returns true if the biome definition is a mineral thermal source.
static func is_hot_spring_biome(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE


## Check whether a zone should produce a thermal source depression.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return is_hot_spring_biome(bd)
