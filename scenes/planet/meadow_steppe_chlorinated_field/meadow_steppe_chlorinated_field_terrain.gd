@tool
class_name MeadowSteppeChlorinatedFieldTerrain
## Terrain module for the **meadow_steppe-chlorinated_field** biome.
##
## Salt deserts composed of halides (such as sodium or potassium chloride).
## These plains are often the result of the complete evaporation of ancient salt seas.
## Category: toxic.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "meadow_steppe-chlorinated_field"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 67
## Category tag for grouping.
const CATEGORY := "toxic"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a meadow_steppe-chlorinated_field.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
