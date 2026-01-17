@tool
class_name RockyLandformAlpineMountainTerrain
## Terrain module for the **rocky_landform-alpine_mountain** biome.
##
## A mountain zone located between the tree line and the permanent snow line.
## Characterized by short grasslands (alpine meadows) and flora adapted to
## intense UV radiation and strong winds.
## Category: terrestrial.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "rocky_landform-alpine_mountain"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 23
## Category tag for grouping.
const CATEGORY := "terrestrial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a rocky_landform-alpine_mountain.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
