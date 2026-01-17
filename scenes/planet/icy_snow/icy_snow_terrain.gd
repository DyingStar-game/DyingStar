@tool
class_name IcySnowTerrain
## Terrain module for the **icy-snow** biome.
##
## Permanent blankets of snow ice that increase in density until they
## become firn ice.
## Category: terrestrial.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "icy-snow"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 20
## Category tag for grouping.
const CATEGORY := "terrestrial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is icy-snow.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
