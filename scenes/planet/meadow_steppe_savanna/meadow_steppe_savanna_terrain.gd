@tool
class_name MeadowSteppeSavannaTerrain
## Terrain module for the **meadow_steppe-savanna** biome.
##
## A tropical or subtropical ecosystem characterized by a dry grassy carpet
## dotted with isolated trees, governed by a marked water seasonality
## (alternating dry and rainy seasons).
## Category: terrestrial.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "meadow_steppe-savanna"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 9
## Category tag for grouping.
const CATEGORY := "terrestrial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a savanna.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
