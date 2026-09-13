@tool
class_name RailwaySettings
## What is physically RAIL about a railway: the track module, the bed width
## per track, the ballast, the rail rendering, and the railway's own grade
## policy. Everything about building a line on a grade-limited profile
## (stations, cuttings, tunnels, viaducts, bed skirts) is generic and lives
## in GradeSettings, which asks this class for the railway's answers. This
## class depends on NOTHING (see BALLAST_MATERIAL_PATH) — it sits at the
## bottom of the load order.
##
## Several of these values are mirrored in the QGIS exporter
## (tools/planettech/qgis/export/planet/roads.py — the bed width).

# ── Rail module (assets/_universe/structures/urban/railroad_01.glb) ─────

## The GLB holds HALF a track: half a sleeper with one rail, 1.12 m long
## along its +Z axis. After the node scale is applied its extent is
## 1.22 m (X, across the track) × 0.29 m (Y) × 1.12 m (Z).
const MODULE_PATH := "res://assets/_universe/structures/urban/railroad_01.glb"
const MODULE_LEN_M := 1.12
const MODULE_HALF_W_M := 1.22
## Height of the module's bounding box (sleeper bottom to rail head).
const MODULE_H_M := 0.29
## How far the module's geometry dips under its origin (sleeper underside).
const MODULE_BELOW_M := 0.08
## Lateral position of the rail head's centre in the module: ~standard gauge.
const RAIL_CENTRE_M := 0.76

## One track = two mirrored halves.
const TRACK_W_M := 2.0 * MODULE_HALF_W_M   # 2.44
## Clear gap between the sleeper ends of two adjacent tracks.
const TRACK_GAP_M := 1.0
## Centre-to-centre distance between two adjacent tracks.
const TRACK_PITCH_M := TRACK_W_M + TRACK_GAP_M   # 3.44
## Ballast shoulder on each side of the outermost sleeper end.
const SHOULDER_M := 0.5
## Bed half-width when the record carries no `tracks` (mirrors RoadTerrain).
const DEFAULT_HALF_WIDTH_M := 2.5

# ── Grade policy ─────────────────────────────────────────────────────────

## Steepest grade the track follows; past it the track stays level.
const MAX_GRADE := 0.04
## What the track does in a window whose terrain is steeper than MAX_GRADE:
## false — it stays LEVEL (the first rule as written); true — it climbs
## or descends at exactly MAX_GRADE toward the terrain, the way a real line
## chases a plateau instead of tunnelling under all of it. Chosen (2026-09-13)
## on the tarsis_3 numbers: staying level gave one 13 km tunnel and then ONE
## 536 km viaduct up to 2 612 m tall down the far slope; chasing the terrain
## gives 524 km on the ground, 2 tunnels (12.6 km) and 16.5 km of viaducts
## no taller than 449 m.
const CLIMB_AT_MAX_GRADE := true

# ── Rendering ────────────────────────────────────────────────────────────

## Rail modules are instanced on chunks at this LOD or finer; the module's
## `railroad LOD0/1/2` nodes (2 736 / 900 / 18 triangles) are the tiers, one
## per chunk LOD, so LOD 2 draws the far stretches as bare boxes.
const RAIL_MAX_LOD := 2
## One MultiMeshInstance3D per this many metres of track, so the importer's
## automatic mesh LOD — chosen per node, not per instance — degrades the far
## stretches while the near ones stay sharp.
const RAIL_MMI_GROUP_M := 64.0
## Visibility of a rail group, as a multiple of the chunk diagonal.
const RAIL_VISIBILITY_DIAG := 3.0

## Same directory as GradeSettings.MATERIAL_DIR — spelled out because this
## class must not depend on GradeSettings: GradeSettings → RoadTerrain →
## RailwaySettings is the load order, and a reference back would be a cycle
## that leaves RoadTerrain half-parsed ("static function not found").
const BALLAST_MATERIAL_PATH := "res://assets/_universe/environment/terrain/path_ballast.tres"


## Half-width of the ballast bed for [param tracks] tracks — a railway has no
## `width` in QGIS, the track count decides. MUST match
## railway_half_width_m() in tools/planettech/qgis/export/planet/roads.py.
static func railway_half_width_m(tracks: int) -> float:
	if tracks <= 0:
		return DEFAULT_HALF_WIDTH_M
	return (tracks * TRACK_W_M + (tracks - 1) * TRACK_GAP_M) * 0.5 + SHOULDER_M


## Is this decoded road record a railway?
static func is_railway(zone: Dictionary) -> bool:
	return str(zone.get("road_type", "")) == "railway"

