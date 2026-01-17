@tool
class_name RockyLandformCanyonTerrain
## Self-contained constants and helpers for canyon / gorge terrain depressions.
##
## Canyons are linear biomes with a steep-walled U-profile cross-section
## (1 − t⁴ keeps walls near-vertical with a wide flat floor).
## All constants are local to this module so that changing canyon parameters
## cannot break river or cave biomes.

# ── Constants ──────────────────────────────────────────────────────

## Half-width of canyon / gorge profiles in metres (wider than rivers).
const HALF_WIDTH_M := 120.0
## Default canyon depth when the QGIS depth field is zero (metres).
const DEFAULT_DEPTH_M := 80.0
## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "rocky_landform-canyon"


# ── Detection helpers ──────────────────────────────────────────────

## Returns true if the given zone represents a canyon / gorge.
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
