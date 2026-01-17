@tool
class_name MeadowSteppeSulfurPlainTerrain
## Terrain module for the **meadow_steppe-sulfur_plain** biome.
##
## Yellowish expanses reminiscent of the moon Io. The ground is covered in elemental sulfur and solid sulfur dioxide.
## Category: toxic.  Layer group: individual (1 layer = 1 biome).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "meadow_steppe-sulfur_plain"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 63
## Category tag for grouping.
const CATEGORY := "toxic"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a meadow_steppe-sulfur_plain.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
