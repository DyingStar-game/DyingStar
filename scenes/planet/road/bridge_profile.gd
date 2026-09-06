@tool
class_name BridgeProfile
extends Resource
## Every tunable of a road bridge, in one resource hung on PlanetData.
##
## A Resource rather than a dozen @export vars on PlanetData: it can be unit
## tested on its own with no planet, a designer can share one profile between
## planets, and it yields a single [method signature] for the chunk disk-cache
## key — the road ribbon is CUT to make room for the ramps, so changing a ramp
## slope changes baked chunk meshes and must invalidate them.
##
## ── Why the deck is shaped the way it is ────────────────────────────────
## The deck runs between two RADII, one per rim, each a clearance above its own
## ground, interpolated along the road. Radius — not height above a tangent
## plane — because a constant radius is an equipotential surface under radial
## gravity: a deck whose two ends share a radius is dead level along its whole
## length with no orientation maths at all. The previous implementation put a
## flat module on the tangent plane at ONE sampled altitude, and its far end
## ended up buried in the high rim and floating over the low one.
##
## The deck's own gradient is capped at [member deck_max_slope_deg]; whatever
## height difference is left over is absorbed by RAMPS, never by a step. A ramp
## is something a truck climbs; a step is something it hits.
##
## [member parapet_width_m] is a PHYSICS budget, not styling. A shape thinner
## than the distance a vehicle covers in one physics step can be crossed
## outright, and this project has seen the server tick fall to 10 Hz, where
## 45 km/h covers 1.25 m per step.

## Height of the deck's driving surface above the rim at each end.
@export var deck_clearance_m: float = 0.50

## Steepest the DECK itself may slope, following its two rims.
##
## A level deck has to be referenced to the higher rim, which leaves the low end
## standing in the air by the difference — on tarsis_3 that reaches 236 m, and
## no ramp can climb back from there. Letting the deck take the rims' own
## gradient, up to this, keeps both ends a clearance above their own ground and
## leaves the ramps short. Past this the deck descends at exactly this gradient
## and the ramp on the low side absorbs what is left.
@export var deck_max_slope_deg: float = 5.0

## Ramp gradient. Gentle on purpose: a loaded truck has to climb it from a
## standstill and come back down without the bed unloading its suspension.
@export var ramp_slope_deg: float = 5.0

## How far the ramp toe is driven UNDER the ground. A ramp that stops exactly at
## ground level leaves a lip the width of the collision margin, which is enough
## to catch a wheel; burying the last stretch means the drivable surface emerges
## from the terrain instead of starting on it.
##
## Half a metre rather than the twenty centimetres that look sufficient: the
## ramp is aimed at the heightmap, but what a wheel touches is a TRIANGULATION
## of it, sampled every ~25 m on tarsis_3, and measurement on the real chunk
## shape puts that mesh up to half a metre away from the surface being aimed at.
## Burying less than that discrepancy leaves the toe standing proud again.
@export var ramp_bury_m: float = 0.50

## MINIMUM flat deck kept beyond each rim, so the abutment rests on solid ground
## rather than on the very lip of the crack. The abutment actually used is the
## larger of this and [member abutment_grid_spans] grid spacings.
@export var road_cutback_m: float = 2.0

## Abutment length in TERRAIN GRID SPACINGS, which is what really sizes it.
##
## The rim `crack_offset` describes analytically is not the rim you see or drive
## on. The terrain mesh samples that function at its grid vertices and the crack
## wall is near-vertical, so the last vertex OUTSIDE the crack is the last solid
## ground — and it can be a whole grid spacing further out than the analytic
## rim. The rendered and collided canyon is therefore up to one grid spacing
## WIDER per side than the one the plan measures.
##
## A two-metre abutment lands in that overhang almost every time: on tarsis_3
## the finest grid is ~25 m, so the deck ended in mid-air with a visible gap
## between it and the canyon edge. Sizing the abutment in grid spacings instead
## puts it back on ground that actually exists, at any planet resolution.
@export var abutment_grid_spans: float = 1.5

@export var deck_thickness_m: float = 0.60
@export var parapet_height_m: float = 1.20

## See the class header: this is a physics budget.
@export var parapet_width_m: float = 0.80

## Spacing of the stations the deck is built from, along the road centerline.
## Every original centerline vertex is a station too, so this only bounds the
## sagitta on a curve: 4 m gives 4 cm on a 50 m-radius bend.
@export var deck_segment_m: float = 4.0

## Step of the ramp-toe search. The terrain is a bilinear read of a ~2 km
## height grid, so it is locally straight over tens of metres and a coarse
## probe plus one interpolation lands sub-millimetre.
@export var ramp_probe_step_m: float = 2.0

## How far the ramp search may run. NOT a design cap on a ramp that is simply
## long: when the road CLIMBS away from the rim, the ramp is extended for as
## long as it takes, because stopping it short puts back the step it exists to
## remove. This only bounds the search.
@export var ramp_safety_max_m: float = 600.0

## How far a STEEPENED ramp may run. A gentler slope always lands further out,
## so without a target the search would happily return a six-hundred-metre
## embankment: pleasant to drive, absurd to look at and expensive in triangles.
## This is the run the gentlest landing slope is fitted to.
@export var ramp_steep_max_m: float = 150.0

## Steepest a ramp may get, used only when lengthening cannot work at all.
##
## Lengthening lands a ramp on ground that is level or climbing. It can never
## land on ground FALLING faster than the ramp descends: the gap widens with
## every metre, so an infinitely long ramp still floats. That happens on the
## LOW rim of a gorge in sloping country — the deck is referenced to the high
## rim, so the low end can start twenty metres up. Steepening is then the only
## geometry that connects, and the search takes the gentlest slope that lands.
@export var ramp_max_slope_deg: float = 25.0

## Extra half-width added, linearly, from the flat deck out to the buried toe.
## The deck is built from the WHOLE-road record (decimated at the pack's
## coarsest level) while the ribbon is built from the chunk's fine tile, so the
## two polylines can differ laterally by up to the decimation tolerance
## (~1.5 m for a 6 m road). Flaring the buried end swallows that difference
## instead of leaving a visible ledge beside the tarmac.
@export var ramp_flare_m: float = 1.20

## Grip the deck reports to a vehicle, read through the "grip_slip" metadata.
## Godot's VehicleWheel3D derives its friction budget from suspension force x
## wheel_friction_slip and never reads the ground body's PhysicsMaterial, so
## per-surface grip has to travel this way.
@export var deck_grip_slip: float = 3.0

## Driving surface. Defaults to the same asphalt the ribbon uses, so the road
## does not change material as it crosses.
@export var deck_material_path: String = RoadTerrain.ASPHALT_MATERIAL_PATH

## Sides, underside and parapets.
@export var structure_material_path: String = \
		"res://assets/_universe/environment/terrain/regolith_grey.tres"


## Short digest of every field that changes baked geometry, for the chunk
## disk-cache key. Materials are excluded on purpose: they change how a bridge
## LOOKS, not where the ribbon is cut, so they must not force a terrain re-bake.
func signature() -> String:
	return "%.2f_%.2f_%.2f_%.2f_%.2f_%.2f_%.2f_%.2f_%.2f_%.2f_%.2f" % [
		deck_clearance_m, deck_max_slope_deg, ramp_slope_deg, ramp_bury_m,
		road_cutback_m, abutment_grid_spans,
		deck_thickness_m, parapet_height_m, parapet_width_m,
		deck_segment_m, ramp_flare_m]


## Tangent of the ramp gradient, clamped away from zero and from vertical so a
## mis-typed slope cannot produce an infinite or a zero-length ramp.
func ramp_tan() -> float:
	return tan(deg_to_rad(clampf(ramp_slope_deg, 0.1, 60.0)))


## Tangent of the steepest deck gradient. Zero is allowed here, unlike the ramp:
## it means "keep the deck strictly level", the behaviour before decks were
## allowed to follow their rims.
func deck_tan() -> float:
	return tan(deg_to_rad(clampf(deck_max_slope_deg, 0.0, 45.0)))
