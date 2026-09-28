@tool
class_name LavaSettings
## Lava flows (QGIS layers/volcanoes.py `lava_flow`, pack kind LAVA): what the
## generic grade machinery (GradeSettings / GradeProfile / GradeBed) needs to
## know about them, and their look. Nothing here is road or railway logic —
## a flow is a PROFILED LINE with its own rule:
##
##   · it never flows uphill: its surface is the running minimum of the ground
##     along the drawing direction, [member depth_m] below it (GradeProfile's
##     DESCENT rule) — where the ground rises the channel is cut through it;
##   · no tunnel, no bridge: a flow is a channel or it lies on the ground;
##   · its walls are steeper than a road cutting's (cooled crust stands);
##   · its width goes from width_start_m at the source to width_end_m.
##
## The decoded record (ModifierPack._decode_lava) carries the keys of a road
## (centerline, _cum_lengths, feature_id, half_width_m) so GradeGeom reads it
## as any line, with road_type = [constant LAVA_TYPE].

const LAVA_TYPE := "lava_river"
const STATES: Array[String] = ["active", "cooling", "solid"]

## Rise per metre of a lava channel's banks (1.2 ≈ 50°: cooled crust stands
## steeper than a road cutting's GradeSettings.GORGE_WALL_SLOPE).
## The crust is drawn with the roads (same far-LOD gate and visibility,
## PlanetChunk's road_groups).
const WALL_SLOPE := 1.2
## Texture repeat along / across the flow (m).
const TILE_M := 96.0
## The channel floor is cut this far BELOW the lava surface: the crust then
## meets its banks on the regular part of the wall, not on the floor/wall
## crease — a crust laid on the crease showed the refined grid as a saw-tooth
## edge (the crease falls between sub-vertices).
const CHANNEL_SINK_M := 4.0
## The crust reaches this far (horizontally) into the banks past the line
## where it meets them, so its edge is buried in rock.
const CRUST_BURY_M := 1.5

## Material of the crust per state.
const MATERIAL_BY_STATE := {
	"active": "res://assets/_universe/environment/terrain/lava_flow_active.tres",
	"cooling": "res://assets/_universe/environment/terrain/lava_flow_cooling.tres",
	"solid": "res://assets/_universe/environment/terrain/lava_flow_solid.tres",
}
## The crust is the ground's rock, darkened: its tint × this.
const DARKEN_BY_STATE := {"active": 0.7, "cooling": 0.55, "solid": 0.55}


static func is_lava(zone: Dictionary) -> bool:
	return str(zone.get("road_type", "")) == LAVA_TYPE


static func state_of(zone: Dictionary) -> String:
	var s := str(zone.get("state", "active"))
	return s if s in STATES else "active"


static func material_path_of(zone: Dictionary) -> String:
	return str(MATERIAL_BY_STATE[state_of(zone)])


static func darken_of(zone: Dictionary) -> float:
	return float(DARKEN_BY_STATE[state_of(zone)])


## Depth of the lava surface below the lowest bank seen so far (m).
static func depth_of(zone: Dictionary) -> float:
	return maxf(float(zone.get("depth_m", 2.0)), 0.0)


## How much wider than its carved floor the crust is drawn (m): past the
## meeting line with the banks (CHANNEL_SINK_M up the wall) and buried.
static func crust_overlap_m() -> float:
	return CHANNEL_SINK_M / WALL_SLOPE + CRUST_BURY_M


## Half-width at the source and at the end (m).
static func half_widths_of(zone: Dictionary) -> Vector2:
	var hw := float(zone.get("half_width_m", 10.0))
	var w0 := float(zone.get("width_start_m", 2.0 * hw))
	var w1 := float(zone.get("width_end_m", 2.0 * hw))
	return Vector2(maxf(w0, 1.0) * 0.5, maxf(w1, 1.0) * 0.5)


## Everything above that changes a lava mesh — folded into the chunk cache
## key ("_lv") so a tweak re-bakes the chunks under a flow.
static func signature() -> String:
	return "lv2_%s_%s_%s_%s_%s" % [WALL_SLOPE, TILE_M, CHANNEL_SINK_M, CRUST_BURY_M,
			str(DARKEN_BY_STATE).md5_text().substr(0, 6)]
