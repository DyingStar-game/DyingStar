@tool
class_name PadSettings
## The numbers a TERRAIN PAD is built from — the flat platform levelled under a
## building — ONE place for every constant the pad record, the cross-section,
## the refinement predicate and the editor snap agree on.
##
## Why a static class and not @export vars on the building scene: the same
## values are read on the mesh workers, in the collision builder, by the editor
## snap tool, by the server's surface catch and in the unit tests. A constant
## cannot drift between a client and a server the way a scene property can —
## the same reason GradeSettings exists for the railways.
##
## [method signature] folds every geometry constant into the chunk cache key,
## so changing one here re-bakes the meshes and the collision shapes instead of
## serving a stale pad from disk.

# ── Cross-section ────────────────────────────────────────────────────────

## The flat apron reaches this far past the footprint by default: room to walk
## around the building and to park a vehicle in front of it before the ground
## starts to move. Per-pad overridable (TerrainPad.apron_m).
const APRON_M := 8.0

## Rise of the talus per metre of lateral distance past the apron (1.0 = 45°).
## 0.5 (27°) is comfortably under the character's floor_max_angle (Godot's
## 45°) AND drivable: a truck can climb onto the apron from any side. The
## talus WIDTH is derived from this — it is the height difference that is
## given, the slope that is fixed, so a 2 m step costs 4 m of ground and a
## 12 m step costs 24 m. See the lesson behind GradeSettings.GORGE_WALL_SLOPE:
## a wall at exactly the character's limit makes the player hop in place.
const TALUS_SLOPE := 0.5

## Hard cap on the talus WIDTH. This is a safety bound, not a design choice:
## PadIndex hands a chunk the pads of its own HEALPix pixel plus its eight
## neighbours, exactly like GradeBed.gather_pieces, so a pad whose influence
## reached further than one pixel would be applied by one chunk and ignored by
## the chunk two pixels away — a seam.
##
## Where the cap binds, the slope promised above is the one thing that gives:
## the talus still joins the relief continuously, but steeper. 120 m absorbs a
## 60 m height difference, which is a building halfway down a cliff — and
## TerrainPad says so in the inspector rather than letting it pass quietly.
## Raising this is only safe while a pad's whole reach (PadBed.reach_m) stays
## inside half a finest-level HEALPix pixel: 198 m on tarsis_3.
const TALUS_MAX_M := 120.0

## Extra lateral reach of the pad rule past the talus toe, so the refinement
## band and the rebuild set both cover the last sub-vertex the rule moves.
const REACH_MARGIN_M := 2.0

# ── Pad altitude ─────────────────────────────────────────────────────────

## The raw relief is sampled on a SAMPLE_N × SAMPLE_N grid over the footprint
## plus its apron, and the pad sits at the MEDIAN of those samples. Not the
## mid-point between the lowest and the highest: one corundum crack or one
## boulder crossing a corner would drag a (min+max)/2 pad metres off the
## ground the building actually stands on, while the median ignores it and
## still splits cut and fill evenly on any regular slope.
const SAMPLE_N := 9

# ── Roads ────────────────────────────────────────────────────────────────

## A road is cut where it crosses a pad's FOOTPRINT, plus this margin — a path
## does not run through a warehouse. The apron is deliberately NOT cut: that is
## the ground a vehicle parks on, and a path across it is exactly right.
##
## Why cut at all rather than let the ribbon follow the levelled ground: the
## ribbon is a slab RoadTerrain.SURFACE_THICKNESS_M thick laid ON the terrain,
## so over a pad it sits that much above the platform — and therefore above the
## building's floor, a strip of asphalt raised through the inside of the
## building. Measured on tarsis_3: 10.8 cm above the platform, 3 vertices of it
## inside a cargo depot.
const ROAD_CUT_MARGIN_M := 0.5

## Step the centreline is walked at to find where it enters and leaves a
## footprint. Half of RoadCut.MIN_PIECE_M, so a crossing can never be missed
## between two samples and still be long enough to matter.
const ROAD_CUT_STEP_M := 0.25

# ── Determinism ──────────────────────────────────────────────────────────

## A pad record is quantised to these steps BEFORE anything is computed from
## it. The server owns the building's transform and the client receives it
## through Horizon as float32; without this the two would sample the relief at
## directions differing in the last bits, take a median a micron apart, and
## build a mesh and a collision shape that disagree between machines. Degrees
## at 1e-7 is ~1 cm on a planet, which is finer than the grid the pad is cut
## into and coarser than any float32 round-trip error.
const Q_DEG := 1e-7
const Q_RAD := 1e-4
const Q_M := 0.01

# ── Grid gate ────────────────────────────────────────────────────────────

## The pad is carved only into a grid at least this fine — the same gate, and
## the same refinement factor, as a railway cutting: they share
## GradeBed.carve_enabled and GradeRefine, so a chunk holding both carves both
## or neither. Stated here so a reader of this file sees the whole rule.
const CARVE_MAX_VTX_SPACING_M := GradeSettings.CARVE_MAX_VTX_SPACING_M
const REFINE_K := GradeSettings.REFINE_K


## Cache-key fragment covering every constant that changes baked geometry.
## Folded into PlanetTerrain's _cache_version, so tweaking a number above
## re-bakes the meshes and the shapes instead of serving a stale pad.
static func signature() -> String:
	return "%.1f_%.3f_%.0f_%.1f_%d_%.0e_%.0e_%.2f_%.2f" % [
		APRON_M, TALUS_SLOPE, TALUS_MAX_M, REACH_MARGIN_M,
		SAMPLE_N, Q_DEG, Q_RAD, Q_M, ROAD_CUT_MARGIN_M]
