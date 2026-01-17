@tool
class_name DesertRockyTerrain
## Terrain module for the **aride_desert-rocky_desert** biome.
##
## An arid expanse characterized by bare rock slabs and stone plateaus (mesas) sculpted by erosion.
## Category: terrestrial.  Layer group: individual.
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "aride_desert-rocky_desert"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 6
## Category tag for grouping.
const CATEGORY := "terrestrial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is a aride_desert-rocky_desert.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
