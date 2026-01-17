@tool
class_name IcyHydrocarbonDuneTerrain
## Terrain module for the **icy-hydrocarbon_dune** biome.
##
## Hydrocarbon sand dunes (Titan).
## Category: cryo.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "icy-hydrocarbon_dune"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 48
## Category tag for grouping.
const CATEGORY := "cryo"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is an icy-hydrocarbon_dune.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
