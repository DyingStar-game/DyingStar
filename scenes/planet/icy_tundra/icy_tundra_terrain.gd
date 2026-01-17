@tool
class_name IcyTundraTerrain
## Terrain module for the **icy-tundra** biome.
##
## Polar biome defined by the absence of trees and the presence of frozen
## ground. Vegetation is limited to mosses, lichens, and dwarf shrubs.
## Category: terrestrial.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "icy-tundra"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 19
## Category tag for grouping.
const CATEGORY := "terrestrial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is an icy-tundra.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
