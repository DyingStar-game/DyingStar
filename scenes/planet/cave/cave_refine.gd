class_name CaveRefine
extends RefCounted
## Local refinement of the terrain grid around cave openings, through GradeRefine as for a building pad.
##
## A cave is built on the exact relief (CaveEntrance.ground_in_frame), the terrain shown is a ~25 m grid over it.
## On flat ground the two stay within half a metre, but on a mountain slope the grid's triangles pass up to 5.6 m
## under the relief: an approach's walls and a hangar's hood stood out of the ground (tarsis_3, cave 184,
## 2026-10-31). Every cell near an opening is re-meshed REFINE_K × REFINE_K finer from the relief itself.
##
## The test is a pure function of a grid corner's direction, so two chunks sharing a border judge its cells alike
## (GradeRefine._border_cell_shared): the corner is projected along its direction onto the cave's surface plane and
## tested against the openings' plan rectangles, grown by MARGIN_M and by one grid pitch.

## How far (m) past an opening's footprint the ground is refined: the rim, the hood and the exterior rocks stand
## on the relief up to 6 m past the rim, plus their own extent (the apron of CavePlanetRegistry.site_tiles).
const MARGIN_M := 10.0
## Slack (m) on a cave's extent around its entrance point, before its openings are worked out.
const SITE_SLACK_M := 500.0


## The plan rectangles of [param placement]'s openings, in its surface frame (x, z), not grown. A porch, bored
## along its own tilted frame, is the plan of its whole prism.
static func footprints(placement: CavePlacement) -> Array[Rect2]:
    var inverse := placement.surface_transform().affine_inverse()
    var rects: Array[Rect2] = []
    for opening: Dictionary in placement.openings():
        var to_site := inverse * (opening.frame as Transform3D)
        var half := float(opening.width) * 0.5
        var axis: Vector2 = opening.get("axis", Vector2.ZERO)
        var rect := Rect2()
        var first := true
        for x: float in [-half, half]:
            for y: float in [axis.x, axis.y]:
                for z: float in [-float(opening.length), float(opening.get("back", 0.0))]:
                    var point := to_site * Vector3(x, y, z)
                    var plan := Vector2(point.x, point.z)
                    if first:
                        rect = Rect2(plan, Vector2.ZERO)
                        first = false
                    else:
                        rect = rect.expand(plan)
        rects.append(rect)
    return rects


## The caves whose openings may refine chunk ([param hp_nside], [param hp_ipix]) on a grid of [param pitch_m]:
## [] off the finest grid (GradeBed.carve_enabled, the gate of the pads and cuttings), else one record per cave,
## {inverse, up, level, rects} with the rectangles grown by MARGIN_M.
static func zones(data: PlanetData, hp_nside: int, hp_ipix: int, pitch_m: float) -> Array:
    if hp_nside <= 0 or not GradeBed.carve_enabled(data, hp_nside, pitch_m):
        return []
    var placements := data.stargrot_placements()
    if placements.is_empty():
        return []
    var center := HEALPix.pix2vec_nest(hp_nside, hp_ipix)
    # A pixel's corner is within 1.5 sides of its centre, even where HEALPix pixels are thin rhombi.
    var chunk_reach := 1.5 * HEALPix.pixel_side_length(hp_nside, data.radius) + 2.0 * pitch_m + MARGIN_M
    var result: Array = []
    for placement in placements:
        if placement == null:
            continue
        var site := placement.surface_transform()
        var distance := center.angle_to(site.origin.normalized()) * data.radius
        var extent := placement.profile.length_m + placement.ramp_length_m + placement.network_offset.length()
        if distance > chunk_reach + extent + SITE_SLACK_M:
            continue
        var rects: Array[Rect2] = []
        for rect in footprints(placement):
            rects.append(rect.grow(MARGIN_M))
        result.append(zone(site, rects))
    return result


## One cave's record for [method near]: its surface frame [param site] and the rectangles [param rects] (x, z in
## that frame) whose ground is refined.
static func zone(site: Transform3D, rects: Array[Rect2]) -> Dictionary:
    var up := site.basis.y.normalized()
    return {"inverse": site.affine_inverse(), "up": up, "level": site.origin.dot(up), "rects": rects}


## Does the grid corner along [param direction] stand within [param reach_m] of a cave opening's grown footprint?
## GradeRefine passes one pitch: a cell overlapping a footprint has a corner within its half-diagonal of it.
static func near(zones: Array, direction: Vector3, reach_m: float) -> bool:
    for zone: Dictionary in zones:
        var up: Vector3 = zone.up
        var along := direction.dot(up)
        if along <= 0.0:
            continue
        var local: Vector3 = (zone.inverse as Transform3D) * (direction * (float(zone.level) / along))
        var plan := Vector2(local.x, local.z)
        for rect: Rect2 in zone.rects:
            if rect.grow(reach_m).has_point(plan):
                return true
    return false
