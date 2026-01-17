@tool
class_name IcyGlacierTerrain
## Terrain module for the **icy-glacier** biome.
##
## Continental ice mass resulting from the crystallization of snow.
## Under the effect of its own weight, the ice behaves like a viscous
## fluid, flowing and sculpting valleys.
## Category: terrestrial.  Layer group: individual (polygon).
## This module provides identification constants so that game systems
## can recognise the biome without hard-coding strings everywhere.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "icy-glacier"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 21
## Category tag for grouping.
const CATEGORY := "terrestrial"


# ── Detection helpers ──────────────────────────────────────────────

## Returns [code]true[/code] if the biome definition is an icy-glacier.
static func matches_zone(bd: BiomeDefinition) -> bool:
	return bd != null and bd.biome_type == BIOME_TYPE
