@tool
class_name RockyLandformPressureCanyonTerrain
## Self-contained constants and helpers for pressure canyon terrain depressions.
##
## A deep rift where atmospheric pressure is higher than at the surface.
## Temperature increases with depth.  They use a steep-walled U-profile
## cross-section (1 − t⁴).
## Category: atmosphere.  Layer group: individual (line).

# ── Constants ──────────────────────────────────────────────────────

## Half-width of the pressure canyon profile in metres (very wide rift).
const HALF_WIDTH_M := 200.0
## Default pressure canyon depth when the QGIS depth field is zero (metres).
const DEFAULT_DEPTH_M := 150.0
## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "rocky_landform-pressure_canyon"


# ── Detection helpers ──────────────────────────────────────────────

## Returns true if the given zone represents a rocky_landform-pressure_canyon.
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
