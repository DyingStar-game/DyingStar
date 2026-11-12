class_name MineLayout
extends RefCounted
## The seeded plan of a village mine: a vertical shaft, levels along it, galleries leaving each level, and the
## volumes CaveNetworkMesher turns into rock walls. Pure data, no node: built the same on the server and on every
## client from the mine's seed, on any thread.
##
## Frame: the shaft's axis is the Y axis, the ground at y = 0, everything below it. Every level opens a station (a
## chamber dug into the shaft's wall at -Z) from which its galleries leave, away from the shaft. The vehicle lift (a
## truck elevator, MineSite) stands against the opposite wall at +Z, its platform facing the stations: at each level
## a landing bridges the shaft from the platform to the station, level with its floor.
##
## A gallery's WHOLE route (up to the cap) is drawn here; what is dug of it is a distance along it, its initial
## length plus what players mined (MineSite "faces"). The face never computes a path: the rock just gets out of the
## way of a route that was always there. How far a route may go before it would meet another gallery, the shaft or
## the open air is measured once by the server ([method limits]) and persisted: the decision thresholds a
## distance, and a client one ulp off (Windows sin) must never draw a different mine.

const STYLE_STRAIGHT := "straight"
const STYLE_CHAOTIC := "chaotic"
## Spacing (m) of a straight gallery's route points, and longest step of a chaotic one.
const STEP_M := 8.0
## Spacing (m) of the samples the route checks of [method limits] read.
const CHECK_STEP_M := 2.0
## A gallery is not checked against its siblings until this far (m, straight line) from where it starts: they
## all leave from one station, side by side.
const HUB_CLEAR_M := 25.0
## A gallery's own route is ignored this far back (m along it) by its self-crossing check.
const SELF_CLEAR_M := 30.0
## Spatial hash cell (m) of the route checks.
const HASH_M := 16.0
## Depth (m) under the ground from which the shaft has its flat side (shaft_flat_m): above, it stays round under its
## round collar.
const SHAFT_FLAT_TOP_M := 12.0
## How far (m) a station reaches past the shaft's flat side, into the shaft: its rounded plan is wide there, so the
## shaft's flat cuts its floor along a straight edge wider than the lift's platform.
const STATION_PAST_FLAT_M := 1.0

## Every tunable of a mine, with its default. MineSite passes its exports under these keys (see its tooltips).
const DEFAULTS := {
    "depth_min_m": 250.0,
    "depth_max_m": 1000.0,
    "first_level_m": 40.0,
    "level_spacing_min_m": 60.0,
    "level_spacing_max_m": 90.0,
    # The truck elevator (MineSite) stands against the +Z wall at this radius, its platform hanging to the flat side.
    "shaft_radius_m": 8.5,
    # Distance (m) from the shaft's axis to its flat side on the stations' (-Z) side, under SHAFT_FLAT_TOP_M: the
    # front of the lift's platform runs down it, and every station's floor meets it along a straight edge.
    "shaft_flat_m": 5.5,
    "shaft_roughness_m": 0.5,
    "galleries_min": 2,
    "galleries_max": 6,
    "gallery_width_m": 6.0,
    "gallery_height_m": 4.5,
    "initial_min_m": 20.0,
    "initial_max_m": 60.0,
    "gallery_cap_m": 500.0,
    "wall_roughness_m": 0.6,
    "wall_frequency": 0.35,
    "station_width_m": 24.0,
    "station_length_m": 20.0,
    # Under its vault's top: the vault (graph) still leaves ~5 m where the lift's platform comes in.
    "station_height_m": 12.0,
    "straight_fan_deg": 70.0,
    "straight_grade": 0.02,
    "chaotic_spread_deg": 110.0,
    "chaotic_turn_deg": 60.0,
    "chaotic_grade": 0.15,
    "chaotic_branches_max": 2,
    "gallery_clearance_m": 12.0,
    "min_cover_m": 30.0,
    "cell_m": 1.0,
}


## [param settings] over [constant DEFAULTS].
static func settings_with(settings: Dictionary) -> Dictionary:
    var out := DEFAULTS.duplicate()
    out.merge(settings, true)
    return out


## The plan of the mine of [param seed]. [param style] forces a style ("" = drawn from the seed, half and half).
static func generate(seed: int, settings: Dictionary = {}, style: String = "") -> Dictionary:
    var s := settings_with(settings)
    var rng := RandomNumberGenerator.new()
    rng.seed = seed
    var drawn := STYLE_CHAOTIC if rng.randf() < 0.5 else STYLE_STRAIGHT  # always drawn: the rest of the seed stays put
    if style == STYLE_STRAIGHT or style == STYLE_CHAOTIC:
        drawn = style
    var depth := roundf(rng.randf_range(float(s.depth_min_m), maxf(float(s.depth_min_m), float(s.depth_max_m))))
    var radius := float(s.shaft_radius_m)
    var layout := {"seed": seed, "style": drawn, "depth": depth, "shaft_radius": radius, "settings": s,
        "levels": [], "galleries": []}
    # Levels: one every 60-90 m from the first down; the bottom of the shaft is always the last one.
    var heights: Array[float] = []
    var y := -float(s.first_level_m)
    while y > -depth + float(s.level_spacing_min_m) * 0.75:
        heights.append(y)
        y -= rng.randf_range(float(s.level_spacing_min_m), float(s.level_spacing_max_m))
    heights.append(-depth)
    var half_length := float(s.station_length_m) * 0.5
    for index in heights.size():
        # The station opens on the shaft's flat side (its floor meets the lift's platform there), a little past it.
        var center := Vector3(0.0, heights[index], -(float(s.shaft_flat_m) - STATION_PAST_FLAT_M + half_length))
        layout.levels.append({"index": index, "y": heights[index], "station": center,
            "hub": center - Vector3(0.0, 0.0, half_length - 2.0)})
    for level: Dictionary in layout.levels:
        var count := rng.randi_range(int(s.galleries_min), maxi(int(s.galleries_min), int(s.galleries_max)))
        for index in count:
            var heading: float
            if drawn == STYLE_STRAIGHT:
                # A fan away from the shaft, evenly spread, each heading nudged within a third of its share.
                var fan := deg_to_rad(float(s.straight_fan_deg))
                var share := 2.0 * fan / count
                heading = -fan + share * (index + 0.5) + share * 0.3 * rng.randf_range(-1.0, 1.0)
            else:
                heading = deg_to_rad(float(s.chaotic_spread_deg)) * rng.randf_range(-1.0, 1.0)
            _add_gallery(layout, rng, int(level.index), -1, 0.0, level.hub, heading, s)
    if drawn == STYLE_CHAOTIC:
        # Side branches off the primary galleries, from the part dug at the start.
        var primaries: Array = layout.galleries.duplicate()
        for parent: Dictionary in primaries:
            var branches := rng.randi_range(0, int(s.chaotic_branches_max))
            for index in branches:
                if float(parent.initial_m) < 20.0:
                    break
                var at := rng.randf_range(12.0, float(parent.initial_m) - 4.0)
                var point := point_at(parent, at)
                var side := 1.0 if rng.randf() < 0.5 else -1.0
                var heading := heading_at(parent, at) + side * deg_to_rad(rng.randf_range(45.0, 100.0))
                _add_gallery(layout, rng, int(parent.level), int(parent.id), at, point, heading, s)
    return layout


static func _add_gallery(layout: Dictionary, rng: RandomNumberGenerator, level: int, parent: int, branch_m: float,
        start: Vector3, heading: float, s: Dictionary) -> void:
    var cap := float(s.gallery_cap_m)
    var points := PackedVector3Array([start])
    var lengths := PackedFloat64Array([0.0])
    var initial := roundf(rng.randf_range(float(s.initial_min_m), float(s.initial_max_m)))
    if parent >= 0:
        initial = roundf(initial * 0.6)
    var travelled := 0.0
    var point := start
    if layout.style == STYLE_STRAIGHT:
        var grade := float(s.straight_grade) * rng.randf_range(-1.0, 1.0)
        var direction := _direction(heading, grade)
        while travelled < cap:
            point += direction * STEP_M
            travelled += direction.length() * STEP_M
            points.append(point)
            lengths.append(travelled)
    else:
        var grade := 0.0
        var turn := deg_to_rad(float(s.chaotic_turn_deg))
        var limit := float(s.chaotic_grade)
        while travelled < cap:
            # A run of 8-20 m, then the heading and the grade wander.
            var run := rng.randf_range(STEP_M, 20.0)
            var direction := _direction(heading, grade)
            var pieces := int(ceil(run / STEP_M))
            for piece in pieces:
                point += direction * (run / pieces)
                travelled += direction.length() * (run / pieces)
                points.append(point)
                lengths.append(travelled)
            heading += rng.randf_range(-turn, turn) * 0.5
            grade = clampf(grade + rng.randf_range(-0.08, 0.08), -limit, limit)
    layout.galleries.append({"id": layout.galleries.size(), "level": level, "parent": parent, "branch_m": branch_m,
        "points": points, "lengths": lengths, "initial_m": minf(initial, cap)})


## Horizontal heading [param heading] (rad, 0 = away from the shaft along -Z, positive towards +X) climbing
## [param grade] (rise over run), not normalised: one metre of run.
static func _direction(heading: float, grade: float) -> Vector3:
    return Vector3(sin(heading), grade, -cos(heading))


## The point [param distance] m along [param gallery]'s route.
static func point_at(gallery: Dictionary, distance: float) -> Vector3:
    var points: PackedVector3Array = gallery.points
    var lengths: PackedFloat64Array = gallery.lengths
    if distance <= 0.0:
        return points[0]
    for index in range(1, lengths.size()):
        if lengths[index] >= distance:
            var t := (distance - lengths[index - 1]) / maxf(lengths[index] - lengths[index - 1], 1.0e-9)
            return points[index - 1].lerp(points[index], t)
    return points[points.size() - 1]


## The horizontal heading (rad, see [method _direction]) of [param gallery] at [param distance] m along it.
static func heading_at(gallery: Dictionary, distance: float) -> float:
    var points: PackedVector3Array = gallery.points
    var lengths: PackedFloat64Array = gallery.lengths
    var index := 1
    while index < lengths.size() - 1 and lengths[index] < distance:
        index += 1
    var delta := points[index] - points[index - 1]
    return atan2(delta.x, -delta.z)


## The unit direction [param gallery] runs at [param distance] m along it (grade included).
static func direction_at(gallery: Dictionary, distance: float) -> Vector3:
    var points: PackedVector3Array = gallery.points
    var lengths: PackedFloat64Array = gallery.lengths
    var index := 1
    while index < lengths.size() - 1 and lengths[index] < distance:
        index += 1
    return (points[index] - points[index - 1]).normalized()


## How far (m along its route) each gallery is dug: its initial length plus [param faces] (advance by gallery id,
## as a string), never past [param limits] (the server's measure, by id; absent = not measured yet). A branch whose
## parent does not reach its start yet, or a gallery limited to almost nothing, is absent.
static func dug(layout: Dictionary, faces: Dictionary, limits: Dictionary) -> Dictionary:
    var out := {}
    for gallery: Dictionary in layout.galleries:
        var key := str(gallery.id)
        var reach := float(gallery.initial_m) + float(faces.get(key, 0.0))
        reach = minf(reach, float(layout.settings.gallery_cap_m))
        if limits.has(key):
            reach = minf(reach, float(limits[key]))
        var parent := int(gallery.parent)
        if parent >= 0 and (not out.has(parent) or float(out[parent]) < float(gallery.branch_m) + 2.0):
            continue
        if reach < 4.0:
            continue
        out[int(gallery.id)] = reach
    return out


## Can the face of gallery [param id] still move on: under its cap and its measured limit (none = not yet)?
static func face_open(layout: Dictionary, id: int, faces: Dictionary, limits: Dictionary) -> bool:
    var key := str(id)
    if not limits.has(key):
        return false
    var gallery: Dictionary = layout.galleries[id]
    var reach := float(gallery.initial_m) + float(faces.get(key, 0.0))
    return reach + 0.5 < minf(float(limits[key]), float(layout.settings.gallery_cap_m))


## The volumes CaveNetworkMesher meshes for the galleries dug as [param dug] says ([method dug]): the shaft, the
## floor at its foot, then each station with the galleries leaving it, then the branches off those galleries.
##
## A station and its galleries' segments are one feature ("joins_previous" on a gallery's first segment): joined
## exactly, not blended one after the other. Their floors are at one height where they meet, and each blend added
## the smooth union's quarter of blend_m of air there: under the galleries' start the floor sank 60 cm, a step a
## truck could not climb, 4 m past the lift (playtest 2026-11-12).
static func graph(layout: Dictionary, dug_m: Dictionary) -> Dictionary:
    var s: Dictionary = layout.settings
    var radius := float(layout.shaft_radius)
    var depth := float(layout.depth)
    var amp := float(s.wall_roughness_m)
    var freq := float(s.wall_frequency)
    var volumes: Array[Dictionary] = []
    # The shaft rises 4 m above the ground: the surface is cut at y = 0 (BuildRegion's top), an open rim.
    # Under the collar, flat on the stations' side (CaveNetworkMesher clip_z): the lift's platform runs down it.
    volumes.append({"kind": "shaft", "a": Vector3(0.0, -depth + radius, 0.0), "b": Vector3(0.0, 4.0, 0.0),
        "size": Vector3(radius, 0.0, 0.0), "amp": float(s.shaft_roughness_m), "freq": freq * 0.5,
        "clip_z": -float(s.shaft_flat_m), "clip_top": -SHAFT_FLAT_TOP_M})
    # Its foot: a flat floor over the round end of the shaft.
    var foot := Vector3(0.0, -depth, 0.0)
    volumes.append({"kind": "room", "a": foot, "b": foot, "size": Vector3(radius + 1.0, radius + 6.0, radius + 1.0),
        "e": 2.0, "k": 2.0, "amp": float(s.shaft_roughness_m), "freq": freq * 0.5})
    # The stations: a rounded plan (e 4), under an elliptic vault (k 2) like the galleries' arch, not a flat roof. Each
    # followed by the galleries leaving its hub, joined to it.
    for level: Dictionary in layout.levels:
        volumes.append({"kind": "room", "a": level.station, "b": level.station,
            "size": Vector3(float(s.station_width_m) * 0.5, float(s.station_height_m), float(s.station_length_m) * 0.5),
            "e": 4.0, "k": 2.0, "amp": amp * 0.6, "freq": freq})
        for gallery: Dictionary in layout.galleries:
            if int(gallery.parent) < 0 and int(gallery.level) == int(level.index):
                _append_gallery(volumes, gallery, dug_m, s, true)
    for gallery: Dictionary in layout.galleries:
        if int(gallery.parent) >= 0:
            _append_gallery(volumes, gallery, dug_m, s, false)
    return {"phase": 0.0, "noise_seed": int(layout.seed), "cell_m": float(s.cell_m), "blend_m": 1.0,
        "volumes": volumes, "bounds": bounds(volumes)}


## The segments of [param gallery] up to where [param dug_m] says it is dug, onto [param volumes]: one feature, joined
## to the volume before it when [param joined] (its station).
static func _append_gallery(volumes: Array[Dictionary], gallery: Dictionary, dug_m: Dictionary, s: Dictionary,
        joined: bool) -> void:
    if not dug_m.has(int(gallery.id)):
        return
    var half := float(s.gallery_width_m) * 0.5
    var height := float(s.gallery_height_m)
    var reach := float(dug_m[int(gallery.id)])
    var points: PackedVector3Array = gallery.points
    var lengths: PackedFloat64Array = gallery.lengths
    var ends: Array[Vector3] = [points[0]]
    for index in range(1, points.size()):
        if lengths[index] >= reach:
            ends.append(point_at(gallery, reach))
            break
        ends.append(points[index])
    for index in range(1, ends.size()):
        var segment := {"kind": "tunnel", "a": ends[index - 1], "b": ends[index], "size": Vector3(half, height, 0.0),
            "amp": float(s.wall_roughness_m), "freq": float(s.wall_frequency), "continues_a": index > 1,
            "continues_b": index < ends.size() - 1}
        if index == 1 and joined:
            segment["joins_previous"] = true
        volumes.append(segment)


## [method graph] cut down to the volumes that may reach [param box] (mine frame), for meshing a small piece of the
## mine (MineFracture): the same densities inside the box, from a few volumes. A feature (a gallery, a station with the
## galleries joined to it) is kept whole when any of its volumes reaches the box: the mesher joins them, by their order.
static func graph_near(layout: Dictionary, dug_m: Dictionary, box: AABB) -> Dictionary:
    var full := graph(layout, dug_m)
    var reach := box.grow(2.0)
    var kept: Array[Dictionary] = []
    var run: Array[Dictionary] = []
    var run_hits := false
    for volume: Dictionary in full.volumes:
        var hits := bounds([volume]).intersects(reach)
        # One feature for the mesher: a gallery's next segment, or a gallery joined to its station.
        if bool(volume.get("continues_a", false)) or bool(volume.get("joins_previous", false)):
            run.append(volume)
            run_hits = run_hits or hits
            continue
        if run_hits:
            kept.append_array(run)
        run = [volume]
        run_hits = hits
    if run_hits:
        kept.append_array(run)
    full.volumes = kept
    full.bounds = bounds(kept) if not kept.is_empty() else box
    return full


## The galleries dug as [param dug_m] says whose rock may reach [param box] (mine frame), with how far each is dug:
## all a piece of the mine there depends on (MineFracture.layer_ref). As generous as [method graph_near]'s test.
static func galleries_near(layout: Dictionary, dug_m: Dictionary, box: AABB) -> Dictionary:
    var s: Dictionary = layout.settings
    var relief := maxf(float(s.gallery_width_m) * 0.5, float(s.gallery_height_m)) \
        + absf(float(s.wall_roughness_m)) * 1.6 + 3.0
    var reach := box.grow(2.0 + relief)
    var out := {}
    for gallery: Dictionary in layout.galleries:
        var id := int(gallery.id)
        if not dug_m.has(id):
            continue
        var dug := float(dug_m[id])
        var points: PackedVector3Array = gallery.points
        var lengths: PackedFloat64Array = gallery.lengths
        for index in range(1, points.size()):
            if lengths[index - 1] >= dug:
                break
            var b := points[index] if lengths[index] <= dug else point_at(gallery, dug)
            if AABB(points[index - 1], Vector3.ZERO).expand(b).intersects(reach):
                out[id] = dug
                break
    return out


## The box holding every volume of [param volumes] with its wall relief.
static func bounds(volumes: Array) -> AABB:
    var box := AABB()
    var first := true
    for volume: Dictionary in volumes:
        var size: Vector3 = volume.size
        var reach := maxf(size.x, maxf(size.y, size.z)) + absf(float(volume.get("amp", 0.0))) * 1.6 + 3.0
        for point: Vector3 in [volume.a, volume.get("b", volume.a)]:
            var piece := AABB(point - Vector3.ONE * reach, Vector3.ONE * reach * 2.0)
            box = piece if first else box.merge(piece)
            first = false
    return box


## The [param cell_m]-sized lattice cells (as integer coordinates) a volume of [param graph_data] may reach.
static func cells(graph_data: Dictionary, cell_m: float) -> Dictionary:
    var out := {}
    for volume: Dictionary in graph_data.volumes:
        var box := bounds([volume])
        _cells_of(box, cell_m, out)
    return out


static func _cells_of(box: AABB, cell_m: float, out: Dictionary) -> void:
    var lo := Vector3i((box.position / cell_m).floor())
    var hi := Vector3i((box.end / cell_m).floor())
    for z in range(lo.z, hi.z + 1):
        for y in range(lo.y, hi.y + 1):
            for x in range(lo.x, hi.x + 1):
                out[Vector3i(x, y, z)] = true


## The cells a face moving from [param from_m] to [param to_m] along [param gallery] reshapes.
static func face_cells(layout: Dictionary, gallery: Dictionary, from_m: float, to_m: float, cell_m: float) -> Dictionary:
    var s: Dictionary = layout.settings
    var reach := maxf(float(s.gallery_width_m), float(s.gallery_height_m)) + float(s.wall_roughness_m) * 1.6 + 4.0
    var start := point_at(gallery, maxf(0.0, minf(from_m, to_m) - STEP_M))
    var box := AABB(start, Vector3.ZERO)
    var distance := maxf(0.0, minf(from_m, to_m) - STEP_M)
    var end := maxf(from_m, to_m)
    while distance < end:
        distance = minf(end, distance + CHECK_STEP_M)
        box = box.expand(point_at(gallery, distance))
    var out := {}
    _cells_of(box.grow(reach), cell_m, out)
    return out


## Is [param point] (mine frame) in the mine's air: the shaft, a station, or a gallery dug as [param dug_m] says?
## What exempts a body from the below-surface rescue. Generous by a metre: the walls are rough.
static func contains(layout: Dictionary, dug_m: Dictionary, point: Vector3) -> bool:
    var s: Dictionary = layout.settings
    var radius := float(layout.shaft_radius) + 1.5
    if point.y < 6.0 and point.y > -float(layout.depth) - 2.0 \
            and Vector2(point.x, point.z).length_squared() < radius * radius:
        return true
    var half := Vector3(float(s.station_width_m) * 0.5 + 1.0, 0.0, float(s.station_length_m) * 0.5 + 1.0)
    for level: Dictionary in layout.levels:
        var local: Vector3 = point - (level.station as Vector3)
        if absf(local.x) < half.x and absf(local.z) < half.z and local.y > -2.0 and local.y < float(s.station_height_m) + 2.0:
            return true
    var reach := maxf(float(s.gallery_width_m) * 0.5, float(s.gallery_height_m)) + 1.5
    for gallery: Dictionary in layout.galleries:
        if not dug_m.has(int(gallery.id)):
            continue
        var dug := float(dug_m[int(gallery.id)])
        var points: PackedVector3Array = gallery.points
        var lengths: PackedFloat64Array = gallery.lengths
        for index in range(1, points.size()):
            if lengths[index - 1] >= dug:
                break
            var b := points[index] if lengths[index] <= dug else point_at(gallery, dug)
            var closest := Geometry3D.get_closest_point_to_segment(point, points[index - 1], b)
            if closest.distance_squared_to(point) < reach * reach:
                return true
    return false


## The point of the mine's floor nearest [param point] (mine frame), all in the mine frame: on a gallery dug as
## [param dug_m] says (no closer than [param face_clear_m] to its face, where a fallen layer lies) or a station's.
## Where to put back someone who fell through the rock of the mine.
static func floor_near(layout: Dictionary, dug_m: Dictionary, point: Vector3, face_clear_m: float = 3.0) -> Vector3:
    var s: Dictionary = layout.settings
    var best := Vector3.INF
    var best_distance := INF
    var half := Vector3(float(s.station_width_m) * 0.5 - 1.0, 0.0, float(s.station_length_m) * 0.5 - 1.0)
    for level: Dictionary in layout.levels:
        var station: Vector3 = level.station
        var on := Vector3(clampf(point.x, station.x - half.x, station.x + half.x), station.y,
            clampf(point.z, station.z - half.z, station.z + half.z))
        if on.distance_squared_to(point) < best_distance:
            best_distance = on.distance_squared_to(point)
            best = on
    for gallery: Dictionary in layout.galleries:
        if not dug_m.has(int(gallery.id)):
            continue
        var reach := maxf(0.0, float(dug_m[int(gallery.id)]) - face_clear_m)
        var points: PackedVector3Array = gallery.points
        var lengths: PackedFloat64Array = gallery.lengths
        for index in range(1, points.size()):
            if lengths[index - 1] >= reach:
                break
            var b := points[index] if lengths[index] <= reach else point_at(gallery, reach)
            var on := Geometry3D.get_closest_point_to_segment(point, points[index - 1], b)
            if on.distance_squared_to(point) < best_distance:
                best_distance = on.distance_squared_to(point)
                best = on
    return best


## SERVER: how far (m along its route) each gallery may ever be dug, by id as a string: before it comes within
## the clearance of another gallery's route, of the shaft or of another level's station, crosses itself, or
## keeps less than min_cover_m of rock over it. [param cover] maps a mine-frame point to the rock (m) above it,
## NAN when unknown: then {} (measure again later). Earlier galleries keep their whole route.
static func limits(layout: Dictionary, cover: Callable) -> Dictionary:
    var s: Dictionary = layout.settings
    var cap := float(s.gallery_cap_m)
    var clearance := float(s.gallery_clearance_m)
    var radius := float(layout.shaft_radius) + float(s.gallery_width_m) * 0.5 + 2.0
    var depth := float(layout.depth)
    var min_cover := float(s.min_cover_m)
    var claimed := {}  # Vector3i hash cell -> Array of [point, gallery id, distance along it, level, primary, near start]
    var out := {}
    for gallery: Dictionary in layout.galleries:
        var id := int(gallery.id)
        var start: Vector3 = (gallery.points as PackedVector3Array)[0]
        var parent := int(gallery.parent)
        var branch_m := float(gallery.branch_m)
        var level := int(gallery.level)
        if parent >= 0 and float(out.get(str(parent), 0.0)) < branch_m + 2.0:
            out[str(id)] = 0.0  # its parent never reaches where it would branch
            continue
        var stop := cap
        var distance := 0.0
        var next_cover := 0.0
        var probe := {"id": id, "parent": parent, "branch_m": branch_m, "level": level, "primary": parent < 0}
        while distance < cap:
            distance = minf(cap, distance + CHECK_STEP_M)
            var point := point_at(gallery, distance)
            var near_start := point.distance_to(start) < HUB_CLEAR_M
            probe.distance = distance
            probe.near_start = near_start
            if not near_start and Vector2(point.x, point.z).length() < radius and point.y > -depth - 10.0:
                stop = distance
                break
            if not near_start and _near_station(layout, point, level, clearance):
                stop = distance
                break
            if distance >= next_cover:
                next_cover = distance + 10.0
                var rock: float = cover.call(point)
                if is_nan(rock):
                    return {}
                if rock < min_cover:
                    stop = distance
                    break
            if _hits_claimed(claimed, point, clearance, probe):
                stop = distance
                break
            # The route dug so far becomes rock nobody else, nor this gallery further on, may come near.
            var key := Vector3i((point / HASH_M).floor())
            if not claimed.has(key):
                claimed[key] = []
            (claimed[key] as Array).append([point, id, distance, level, parent < 0,
                point.distance_to(start) < HUB_CLEAR_M * 1.6])
        out[str(id)] = cap if stop >= cap else maxf(0.0, stop - float(s.gallery_width_m))
    return out


static func _near_station(layout: Dictionary, point: Vector3, own_level: int, clearance: float) -> bool:
    var s: Dictionary = layout.settings
    var half := Vector3(float(s.station_width_m) * 0.5, float(s.station_height_m), float(s.station_length_m) * 0.5)
    for level: Dictionary in layout.levels:
        if int(level.index) == own_level:
            continue
        var local: Vector3 = point - (level.station as Vector3)
        if absf(local.x) < half.x + clearance and absf(local.z) < half.z + clearance \
                and local.y > -clearance and local.y < half.y + clearance:
            return true
    return false


## Does [param point] come within [param clearance] of a claimed route sample? [param probe] says whose point it
## is: its own route counts from SELF_CLEAR_M back; its parent's not near where it branches; and galleries leaving
## the same station side by side are not compared while either is near its start (HUB_CLEAR_M, ×1.6 for the one
## already claimed: two routes 20° apart are clear of each other from about there).
static func _hits_claimed(claimed: Dictionary, point: Vector3, clearance: float, probe: Dictionary) -> bool:
    var center := Vector3i((point / HASH_M).floor())
    var reach := int(ceil(clearance / HASH_M))
    var id := int(probe.id)
    var distance := float(probe.distance)
    for dz in range(-reach, reach + 1):
        for dy in range(-reach, reach + 1):
            for dx in range(-reach, reach + 1):
                var bucket: Variant = claimed.get(center + Vector3i(dx, dy, dz))
                if bucket == null:
                    continue
                for sample: Array in bucket:
                    var other := int(sample[1])
                    if other == id:
                        if distance - float(sample[2]) < SELF_CLEAR_M:
                            continue
                    elif other == int(probe.parent):
                        if absf(float(sample[2]) - float(probe.branch_m)) < HUB_CLEAR_M:
                            continue
                    elif probe.primary and bool(sample[4]) and int(sample[3]) == int(probe.level) \
                            and (probe.near_start or bool(sample[5])):
                        continue
                    if (sample[0] as Vector3).distance_squared_to(point) < clearance * clearance:
                        return true
    return false
