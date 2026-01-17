@tool
class_name IcySublimationPitTerrain
## Terrain module for the **icy-sublimation_pit** biome.
##
## A rugged terrain formed by the direct transition of CO2 ice from a solid
## to a gaseous state under the effect of solar radiation, creating irregular
## depressions.
## Category: cryo.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "icy-sublimation_pit"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 51
## Category tag for grouping.
const CATEGORY := "cryo"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is an icy-sublimation_pit.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
