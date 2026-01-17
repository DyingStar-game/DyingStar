@tool
class_name VolcanicGeothermalIceGeyserTerrain
## Self-contained constants and helpers for ice geyser terrain depressions.
##
## A cryovolcanic phenomenon where plumes of water vapor, nitrogen, or
## methane are expelled from the depths.
## Category: cryo.  Layer group: individual (point).
## All constants are local to this module — independent of other biomes.

# ── Constants ──────────────────────────────────────────────────────

## Radius of the terrain depression around the geyser (metres).
const DEPRESSION_RADIUS_M := 12.0
## Depth of the depression at the geyser centre (metres).
const DEPRESSION_DEPTH_M := 5.0
## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "volcanic_geothermal-ice_geyser"


# ── Detection helpers ──────────────────────────────────────────────

## Returns true if the biome definition is an ice geyser.
static func is_ice_geyser_biome(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE


## Check whether a zone should produce an ice geyser depression.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return is_ice_geyser_biome(bd)
