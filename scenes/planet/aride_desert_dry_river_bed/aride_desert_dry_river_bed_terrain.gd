@tool
class_name ArideDesertDryRiverBedTerrain
## Self-contained constants and helpers for dry river bed terrain depressions.
##
## A former dried-up channel. The soil is composed of rounded pebbles
## and stratified sediments.  They use a U-profile cross-section
## (1 − t⁴) to give a flat floor with gentle banks.
## Category: martian.  Layer group: individual (line).

# ── Constants ──────────────────────────────────────────────────────

## Half-width of the dry river bed profile in metres.
const HALF_WIDTH_M := 40.0
## Default dry river bed depth when the QGIS depth field is zero (metres).
const DEFAULT_DEPTH_M := 15.0
## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "aride_desert-dry_river_bed"
## Pebble texture tile size in metres (UV tiling for the riverbed pebble overlay).
const TILE_M := 2.0
## Path to the pebble material used as an overlay on the riverbed floor.
const MATERIAL_PATH := "res://assets/materials/planet/riverbed_pebbles.tres"


# ── Detection helpers ──────────────────────────────────────────────

## Returns true if the given zone represents an aride_desert-dry_river_bed.
static func matches_zone(bd: BiomeDefinition, zone: Dictionary) -> bool:
	if bd == null or bd.biome_type != BIOME_TYPE:
		return false
	var cl: PackedVector2Array = zone.get("centerline", PackedVector2Array())
	return cl.size() >= 2


## Ensure the zone dictionary has its half_width_deg pre-computed.
## Called once per zone (not per vertex) for performance.
static func prepare_zone(zone: Dictionary, planet_radius: float) -> void:
	if not zone.get("_hw_converted", false):
		var m_per_deg := planet_radius * PI / 180.0
		zone["half_width_deg"] = HALF_WIDTH_M / m_per_deg
		zone["_hw_converted"] = true
