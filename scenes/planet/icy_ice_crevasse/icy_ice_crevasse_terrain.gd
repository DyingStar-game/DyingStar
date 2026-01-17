@tool
class_name IcyIceCrevasseTerrain
## Self-contained constants and helpers for ice crevasse terrain depressions.
##
## Ice crevasses are deep structural ruptures within glacial bodies or thick
## ice packs.  They use a steep-walled U-profile cross-section (1 − t⁴) like
## canyons but are significantly narrower and can be very deep for their width.
## All constants are local to this module — independent of other biomes.

# ── Constants ──────────────────────────────────────────────────────

## Half-width of the ice crevasse profile in metres (narrow fracture).
const HALF_WIDTH_M := 30.0
## Default crevasse depth when the QGIS depth field is zero (metres).
const DEFAULT_DEPTH_M := 60.0
## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "icy-ice_crevasse"


# ── Detection helpers ──────────────────────────────────────────────

## Returns true if the given zone represents an ice crevasse.
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
