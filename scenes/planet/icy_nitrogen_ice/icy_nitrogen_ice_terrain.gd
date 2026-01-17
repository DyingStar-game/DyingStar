@tool
class_name IcyNitrogenIceTerrain
## Terrain module for the **icy-nitrogen_ice** biome.
##
## A plain composed of solidified nitrogen with internal convection currents.
## Category: cryo.  Layer group: individual (polygon).
## Includes a default depth constant used by PlanetChunk when the
## QGIS feature has no explicit depth value.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "icy-nitrogen_ice"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 46
## Category tag for grouping.
const CATEGORY := "cryo"
## Default liquid depth when the QGIS feature has no depth value (metres).
const DEFAULT_DEPTH_M := 10.0


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is an icy-nitrogen_ice.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
