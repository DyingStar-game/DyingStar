@tool
class_name MaritimeRiverRiverTerrain
## Self-contained constants and helpers for maritime_river-river terrain depressions and water.
##
## Rivers are liquid biomes with a centerline and progressive width
## (width_start → width_end).  The terrain is carved using a parabolic
## cross-section (1 − t²), with depth proportional to width (1:10 ratio).
## A water-surface overlay mesh sits at the carved river-bed elevation
## following a monotonically decreasing slope.
## All constants are local to this module so that changing river parameters
## cannot break canyon or cave biomes.

# ── Constants ──────────────────────────────────────────────────────

## Depth-to-width ratio: depth = width * DEPTH_RATIO.
## Example: 50 m wide → 5 m deep.
const DEPTH_RATIO := 0.1

## Height of the river water surface above the carved river-bed (metres).
## Keeps the water just above the deepest point so terrain peeks at edges.
const WATER_OFFSET := 0.3


# ── Detection helpers ──────────────────────────────────────────────

## Returns true if the given zone represents a river.
## A river is a liquid biome with a centerline of at least 2 points.
## Note: does NOT require data.has_ocean — rivers are self-sufficient
## (the global has_ocean flag controls ocean sphere rendering, not rivers).
static func matches_zone(bd: BiomeDefinition, zone: Dictionary, _data: PlanetData = null) -> bool:
	if bd == null or not bd.is_liquid:
		return false
	var cl: PackedVector2Array = zone.get("centerline", PackedVector2Array())
	return cl.size() >= 2


## Ensure the zone dictionary has progressive width data pre-computed
## in degree units.  Called once per zone (not per vertex) for performance.
static func prepare_zone(zone: Dictionary, planet_radius: float) -> void:
	if not zone.get("_river_prepared", false):
		var m_per_deg := planet_radius * PI / 180.0
		# Read progressive width; fall back to legacy single width.
		var ws: float = zone.get("width_start", 0.0)
		var we: float = zone.get("width_end", 0.0)
		if ws <= 0.0 and we <= 0.0:
			var w: float = zone.get("width", 100.0)
			ws = w
			we = w
		zone["width_start_m"] = ws
		zone["width_end_m"] = we
		zone["half_width_start_deg"] = (ws * 0.5) / m_per_deg
		zone["half_width_end_deg"] = (we * 0.5) / m_per_deg
		zone["half_width_max_deg"] = maxf(ws, we) * 0.5 / m_per_deg
		# Pre-compute cumulative segment lengths for along_t.
		var cl: PackedVector2Array = zone.get("centerline", PackedVector2Array())
		if cl.size() >= 2:
			var cum := PackedFloat64Array()
			cum.resize(cl.size())
			cum[0] = 0.0
			for i in range(1, cl.size()):
				var dx := (cl[i].x - cl[i - 1].x) * m_per_deg
				var dy := (cl[i].y - cl[i - 1].y) * m_per_deg
				cum[i] = cum[i - 1] + sqrt(dx * dx + dy * dy)
			zone["_cum_lengths"] = cum
			zone["_total_length"] = cum[cl.size() - 1]
		else:
			zone["_cum_lengths"] = PackedFloat64Array()
			zone["_total_length"] = 0.0
		zone["_river_prepared"] = true
