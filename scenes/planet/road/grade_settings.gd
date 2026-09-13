@tool
class_name GradeSettings
## The numbers a GRADE-LIMITED LINE is built from — a railway, or a highway /
## road whose QGIS `max_slope_degrees` is set — ONE place for every constant
## the profile, the bed, the cuttings, the viaducts and the tunnels agree on.
##
## What differs between the two kinds of line (the max grade, the climb
## policy, the bed width and material) is asked HERE through the *_of()
## routers below, so GradeProfile / GradeBed / GradeTunnel / GradeRefine never
## test a road type themselves. RailwaySettings holds what is physically
## rail (modules, tracks, ballast); RoadTerrain holds the road answers.
##
## Why a static class and not @export vars on PlanetData: the same values are
## read on the mesh workers, in the collision builder, by the prop spawners and
## by the unit tests, and several of them are mirrored in the QGIS exporter.
## A constant cannot drift between a client and a server the way a scene
## property can.
##
## [method signature] folds every geometry constant into the chunk cache key,
## so changing one here re-bakes the meshes and the collision shapes instead of
## serving a stale bed from disk.

# ── Longitudinal profile ─────────────────────────────────────────────────

## Terrain is read every STATION_STEP_M along the line to classify it.
const STATION_STEP_M := 5.0
## The grade rule is evaluated per window of this length.
const WINDOW_M := 200.0
## Terrain this far above the line (or more) is tunnelled, not cut.
const TUNNEL_MIN_COVER_M := 10.0
## Terrain higher than this above the line counts as a cutting. Below it the
## ground is merely shaved under the bed (the carve rule runs on GROUND runs
## too); the threshold keeps a followed window, where the terrain hugs the
## line to within centimetres, from being classified as a string of cuttings.
const GORGE_MIN_M := 0.5
## A tunnel shorter than this is dug as a cutting instead.
const MIN_TUNNEL_M := 30.0
## A cutting shorter than this BETWEEN two tunnels joins them.
const MIN_GORGE_BETWEEN_TUNNELS_M := 10.0
## Thickness of the bed / the viaduct deck, and the deepest gap the bed's own
## skirts close without a viaduct.
const BED_THICKNESS_M := 2.0
## A gap shorter than this is bridged by the skirts, not by a viaduct.
const MIN_SPAN_M := 24.0
## Deck margin past the measured gap at each end of a viaduct.
const VIADUCT_ABUTMENT_M := 2.0
## A long viaduct is built as consecutive decks no longer than this: a deck
## is one body at one float32 origin, and it is spawned by the chunk holding
## its midpoint — a kilometres-long single deck would vanish whenever the
## player was far from its middle.
const VIADUCT_MAX_SPAN_M := 400.0

# ── Cutting (gorge) ──────────────────────────────────────────────────────

## Flat floor of a cutting extends at least this far past the bed. The
## actual margin is never less than one refined sub-cell plus a little
## (GradeBed.floor_margin_m): the wall is triangulated between sub-vertices,
## so it starts rising up to one sub-cell BEFORE its analytic foot — with a
## 0.5 m margin on a 1.7 m sub-grid it climbed over the ballast onto the
## sleepers.
const GORGE_FLOOR_MARGIN_M := 2.0
## Rise of the cutting wall per metre of lateral distance (1.0 = 45°).
const GORGE_WALL_SLOPE := 1.0
## Extra lateral reach of the cutting rule past the wall's theoretical top.
const GORGE_BAND_MARGIN_M := 2.0
## The cutting is carved only into a grid at least this fine — binary, never
## faded, so the finest mesh and the fine collision carve identically. The
## walls are triangulated on the REFINED sub-grid (the coarse pitch over
## REFINE_K), so the gate is on the sub-cell: a coarse pitch up to
## CARVE_MAX_SUBCELL_M × REFINE_K qualifies. With the first value (20 m of
## coarse pitch) tarsis_3, whose finest grid is 24.8 m at res 32 on a
## 6 356 km body, carved nothing: no cutting, no tunnel tube, and the track
## ran straight into the mountain. 4 m sub-cells (32 m pitch) admit every
## body up to ~8 000 km of radius; the gas-giant-sized ones stay uncarved.
const CARVE_MAX_SUBCELL_M := 4.0
const CARVE_MAX_VTX_SPACING_M := CARVE_MAX_SUBCELL_M * REFINE_K

# ── Bed ──────────────────────────────────────────────────────────────────

## The bed's skirts reach this far under the ground so no lip shows.
const SKIRT_BURY_M := 0.5

# ── Tunnel ───────────────────────────────────────────────────────────────

## Bore half-width past the bed, and clear height above the line.
const BORE_EXTRA_HW_M := 1.0
const BORE_H_M := 6.0
const TUNNEL_WALL_M := 0.5
## The tube runs this far out of the mountain at each end (a false tunnel).
const PORTAL_HOOD_M := 4.0
## The headwall reaches this far past the bore on each side and above it.
const PORTAL_COLLAR_M := 3.5
## Terrain refinement around cuttings and portals: subdivision per grid cell,
## and how far along the line a portal's refinement reaches.
const REFINE_K := 8
const PORTAL_REFINE_M := 20.0

# ── Materials ────────────────────────────────────────────────────────────

const MATERIAL_DIR := "res://assets/_universe/environment/terrain/"
## Tunnel shells, portals, viaduct piers: concrete-grey for every line kind.
const STRUCTURE_MATERIAL_PATH := MATERIAL_DIR + "regolith_grey.tres"

## Segment kinds of a profile (see GradeProfile).
enum Kind { GROUND = 0, GORGE = 1, TUNNEL = 2, BRIDGE = 3 }

## Viaduct deck: a parapet a person can lean on, no road-style flare.
const VIADUCT_PARAPET_H_M := 0.9
const VIADUCT_PARAPET_W_M := 0.4
const VIADUCT_SEGMENT_M := 4.0

## Span kinds a profile's BRIDGE segments are reported as — kept apart from
## the crack-based road spans so bridge_spawner picks the profile plan.
const SPAN_KIND_RAILWAY := "railway"
const SPAN_KIND_ROAD := "profiled_road"
const PROFILE_SPAN_KINDS: PackedStringArray = [SPAN_KIND_RAILWAY, SPAN_KIND_ROAD]

## deck material path → BridgeProfile
static var _viaduct_profiles: Dictionary = {}


# ── Per-line routing ─────────────────────────────────────────────────────
# Every question the generic builders have about "what kind of line is this"
# is answered here and only here.

## Does this decoded road record ride a grade-limited profile?
static func is_profiled(zone: Dictionary) -> bool:
	return RailwaySettings.is_railway(zone) or RoadTerrain.is_graded_road(zone)


## Steepest grade (rise / run) the line follows.
static func max_grade_of(zone: Dictionary) -> float:
	if RailwaySettings.is_railway(zone):
		return RailwaySettings.MAX_GRADE
	return RoadTerrain.max_grade(zone)


## In a window steeper than the max grade: climb at that grade toward the
## terrain (true), or stay level (false)?
static func climbs_at_max_grade_of(zone: Dictionary) -> bool:
	if RailwaySettings.is_railway(zone):
		return RailwaySettings.CLIMB_AT_MAX_GRADE
	# A road chases the hill at its allowed slope; staying level would send
	# every graded road straight into a tunnel.
	return true


## Half-width of the bed in metres.
static func half_width_of(zone: Dictionary) -> float:
	if RailwaySettings.is_railway(zone):
		return RailwaySettings.railway_half_width_m(int(zone.get("tracks", 0)))
	return RoadTerrain.get_half_width_m(zone)


## Material of the bed top (and of the viaduct deck).
static func bed_material_of(zone: Dictionary) -> String:
	if RailwaySettings.is_railway(zone):
		return RailwaySettings.BALLAST_MATERIAL_PATH
	return RoadTerrain.ASPHALT_MATERIAL_PATH


## The kind a BRIDGE segment of this line's profile is reported as.
static func span_kind_of(zone: Dictionary) -> String:
	if RailwaySettings.is_railway(zone):
		return SPAN_KIND_RAILWAY
	return SPAN_KIND_ROAD


## Is this span one planned by GradeProfile (as opposed to a crack span)?
static func is_profile_span(span: Dictionary) -> bool:
	return str(span.get("kind", "")) in PROFILE_SPAN_KINDS


## The deck settings a viaduct is built with (see BridgeDeck): the bed's
## thickness, the bed material on top, no ramps. Memoised per deck material;
## preload-only so it is usable from the editor preview too.
static func viaduct_profile(deck_material: String) -> BridgeProfile:
	if not _viaduct_profiles.has(deck_material):
		var p := BridgeProfile.new()
		p.deck_clearance_m = 0.0
		p.road_cutback_m = VIADUCT_ABUTMENT_M
		p.abutment_grid_spans = 0.0
		p.deck_thickness_m = BED_THICKNESS_M
		p.parapet_height_m = VIADUCT_PARAPET_H_M
		p.parapet_width_m = VIADUCT_PARAPET_W_M
		p.deck_segment_m = VIADUCT_SEGMENT_M
		p.ramp_flare_m = 0.0
		p.deck_material_path = deck_material
		p.structure_material_path = STRUCTURE_MATERIAL_PATH
		_viaduct_profiles[deck_material] = p
	return _viaduct_profiles[deck_material]


## The viaduct profile of a given span kind (bridge_spawner).
static func viaduct_profile_for_span(span: Dictionary) -> BridgeProfile:
	if str(span.get("kind", "")) == SPAN_KIND_RAILWAY:
		return viaduct_profile(RailwaySettings.BALLAST_MATERIAL_PATH)
	return viaduct_profile(RoadTerrain.ASPHALT_MATERIAL_PATH)


## Cache-key fragment covering every constant that changes baked geometry —
## the railway's own (module size, track pitch, grade policy) included, since
## its bed is baked by the same builders.
static func signature() -> String:
	return "%.2f_%.2f_%.2f_%.2f_%.1f_%.0f_%.3f_%.0f_%.0f_%.0f_%.1f_%.0f_%.1f_%.1f_%.1f_%.1f_%.0f_%.1f_%.1f_%.1f_%.1f_%.1f_%.1f_%d_%.0f" % [
		RailwaySettings.MODULE_LEN_M, RailwaySettings.MODULE_HALF_W_M,
		RailwaySettings.TRACK_GAP_M, RailwaySettings.SHOULDER_M,
		STATION_STEP_M, WINDOW_M, RailwaySettings.MAX_GRADE, TUNNEL_MIN_COVER_M,
		MIN_TUNNEL_M, MIN_GORGE_BETWEEN_TUNNELS_M, BED_THICKNESS_M + GORGE_MIN_M,
		MIN_SPAN_M, VIADUCT_ABUTMENT_M, GORGE_FLOOR_MARGIN_M,
		GORGE_WALL_SLOPE, GORGE_BAND_MARGIN_M, CARVE_MAX_VTX_SPACING_M,
		SKIRT_BURY_M, BORE_EXTRA_HW_M, BORE_H_M, TUNNEL_WALL_M,
		PORTAL_HOOD_M, PORTAL_COLLAR_M, REFINE_K, PORTAL_REFINE_M] \
		+ "_%.1f_%.1f_%.0f_c%d_%.0f_g2" % [VIADUCT_PARAPET_H_M, VIADUCT_PARAPET_W_M, VIADUCT_SEGMENT_M,
			int(RailwaySettings.CLIMB_AT_MAX_GRADE), VIADUCT_MAX_SPAN_M]
