@tool
class_name UrbanLandingPadTerrain
## Terrain module for the **urban-landing_pad** biome.
##
## Stabilized and reinforced platform designed to withstand the thermal and mechanical stresses of spacecraft propulsion systems.
## Category: artificial.  Layer group: individual (point).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ────────────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "urban-landing_pad"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 83
## Category tag for grouping.
const CATEGORY := "artificial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a urban-landing_pad.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
