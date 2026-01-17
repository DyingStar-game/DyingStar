@tool
class_name MeadowSteppeWastelandIrradiatedTerrain
## Terrain module for the **meadow_steppe-wasteland_irradiated** biome.
##
## Environmental wasteland with high residual radiological contamination.
## Category: artificial.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ────────────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "meadow_steppe-wasteland_irradiated"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 84
## Category tag for grouping.
const CATEGORY := "artificial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a meadow_steppe-wasteland_irradiated.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
