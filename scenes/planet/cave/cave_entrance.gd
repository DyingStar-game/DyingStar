class_name CaveEntrance
extends RefCounted
## Every opening of a placed cave (porch, doline, light shafts, exit) shares exact ground queries and terrain
## clipping frames.

## Depth (m) under the relief where the ground cover is gone: on rock faces, and on flat floors and talus.
const COVER_STEEP_M := 1.5
const COVER_FLAT_M := 6.0
## Rim seal (seal_rim). The terrain shown is a mesh of ~25 m cells over a smoother relief, so the cut ground's
## edge stands up to ~0.6 m above or below a rim built on the exact relief: a slit. The rim's lip rises LIP_M
## above the ground LIP_OUT_M outside the cut and dips back KNEE_DROP_M under it KNEE_M out (a narrow rounded
## lip, not a berm), then a collar runs COLLAR_M out under the ground, its outer edge COLLAR_DROP_M below it,
## and a curtain hangs CURTAIN_M from that edge for a ground shown even lower.
const LIP_M := 0.6
const LIP_OUT_M := 0.4
const KNEE_M := 1.0
const KNEE_DROP_M := 0.3
const COLLAR_M := 3.0
const COLLAR_DROP_M := 1.0
const CURTAIN_M := 2.0
const ROOF_OUT_ERROR := "La grotte ressort du terrain : choisir un autre emplacement."

## The ground (cracks included) under the site-frame plan point ([param x], [param z]), in the site frame. Native
## inside a CaveGround job, the same value as PlanetData.crack_aware_surface_dist.
static func ground_in_frame(data: PlanetData, frame: Transform3D, x: float, z: float) -> Vector3:
    var direction := (frame * Vector3(x, 0.0, z)).normalized()
    return frame.affine_inverse() * (direction * CaveGround.surface_dist(data, direction))

static func ground_point(data: PlanetData, placement: CavePlacement, x: float, z: float) -> Vector3:
    return ground_in_frame(data, placement.surface_transform(), x, z)

## Walls and floors of the openings, in the site frame, built against the terrain.
static func build(data: PlanetData, placement: CavePlacement, cave: Dictionary = {}) -> Dictionary:
    var spec := placement.profile.snapshot(placement.seed)
    var wall := CaveGenerator._empty_surface()
    var floor_surface := CaveGenerator._empty_surface()
    var decor_sections: Array[Dictionary] = []
    var exposed_walls: Array[Dictionary] = []
    for opening: Dictionary in placement.openings():
        if opening.kind == "approach":
            continue  # built with its porch, whose mouth it frames
        if cave.is_empty():
            cave = CaveGenerator.build(spec)
        if opening.kind == "porch":
            var porch := CavePortal.build_porch(data, placement, opening)
            for part: Dictionary in [porch, porch.get("approach", {})]:
                if not part.is_empty():
                    _append_surface(wall, part.wall, Transform3D.IDENTITY)  # built in the site frame
                    _append_surface(floor_surface, part.floor, Transform3D.IDENTITY)
            decor_sections.append({"rings": porch.rings})
        elif opening.kind in ["skylight", "light"]:
            var skylight := CavePortal.build_skylight(data, placement, opening, cave)
            _append_surface(wall, skylight.wall, Transform3D.IDENTITY)
            if opening.kind == "skylight":
                exposed_walls.append(skylight.exposed_wall)
        else:
            # The exit: a weathered bowl down to the network's far ring.
            var roof := PackedVector3Array()
            for point: Vector3 in cave.exit_ring:
                roof.append(Vector3(-point.x, point.y + float(spec.depth_m), 0))
            roof.reverse()
            var natural := CaveNaturalOpening.build(data, opening, roof)
            var local_frame := placement.surface_transform().affine_inverse() * (opening.frame as Transform3D)
            _append_surface(wall, natural.wall, local_frame)
            _append_surface(floor_surface, natural.floor, local_frame)
    var rock_supports := CaveEntranceRocks.supports(data, placement, wall, exposed_walls)
    var faces: PackedVector3Array = wall.vertices.duplicate()
    faces.append_array(floor_surface.vertices)
    smooth_normals([wall, floor_surface])
    ground_cover(data, placement.surface_transform(), [wall, floor_surface])
    return {"wall": wall, "floor": floor_surface, "faces": faces, "spec": spec, "bounds": AABB(),
        "decor_sections": decor_sections, "rock_supports": rock_supports}


## How much of the planet's own ground lies on each vertex, in COLOR.r (CaveGroundCover paints it): full at
## the relief's level, gone COVER_STEEP_M under it on rock faces and COVER_FLAT_M under it on flat floors and
## talus, where drift settles. The relief is read once per quarter metre of plan.
static func ground_cover(data: PlanetData, frame: Transform3D, surfaces: Array[Dictionary]) -> void:
    var heights := {}
    for surface in surfaces:
        var vertices: PackedVector3Array = surface.vertices
        var normals: PackedVector3Array = surface.normals
        var colors := PackedColorArray()
        colors.resize(vertices.size())
        for index in vertices.size():
            var plan := Vector2(vertices[index].x, vertices[index].z).snappedf(0.25)
            if not heights.has(plan):
                heights[plan] = ground_in_frame(data, frame, plan.x, plan.y).y
            var depth := maxf(0.0, float(heights[plan]) - vertices[index].y)
            var fade := lerpf(COVER_STEEP_M, COVER_FLAT_M, smoothstep(0.55, 0.9, normals[index].y))
            var cover := 1.0 - smoothstep(0.0, fade, depth)
            colors[index] = Color(cover, cover, cover)
        surface.colors = colors

## Seals an open-air rim to the terrain shown around it, whatever its level of detail: from each rim point
## (on the exact relief, where the walls end and the terrain is cut) a lip rising [param lift] × LIP_M just
## outside the cut, a collar down under the ground and a curtain below it, appended to [param wall] in the
## frame of [param rim]. [param outward] holds each point's plan direction away from the opening; [param lift]
## (0..1) lowers the lip where a path walks in. The ground cover paints them like the ground around.
static func seal_rim(data: PlanetData, frame: Transform3D, rim: PackedVector3Array, outward: PackedVector3Array,
        lift: PackedFloat32Array, closed: bool, wall: Dictionary) -> void:
    var lips := PackedVector3Array()
    var knees := PackedVector3Array()
    var collars := PackedVector3Array()
    for index in rim.size():
        var plan := Vector3(outward[index].x, 0.0, outward[index].z).normalized()
        var lip := rim[index] + plan * LIP_OUT_M
        lip.y = ground_in_frame(data, frame, lip.x, lip.z).y + LIP_M * lift[index]
        lips.append(lip)
        var knee := rim[index] + plan * KNEE_M
        knee.y = ground_in_frame(data, frame, knee.x, knee.z).y - KNEE_DROP_M
        knees.append(knee)
        var collar := rim[index] + plan * COLLAR_M
        collar.y = ground_in_frame(data, frame, collar.x, collar.z).y - COLLAR_DROP_M
        collars.append(collar)
    var count := rim.size() if closed else rim.size() - 1
    for index in count:
        var next := (index + 1) % rim.size()
        var out := ((outward[index] + outward[next]) * 0.5).normalized()
        var a := rim[index]
        var b := rim[next]
        CaveGenerator._quad(wall, a, b, lips[next], lips[index], (a + b) * 0.5 + Vector3.UP * 3.0 - out)
        for ring: Array in [[lips, knees], [knees, collars]]:
            CaveGenerator._quad(wall, ring[0][index], ring[0][next], ring[1][next], ring[1][index],
                (ring[0][index] + ring[1][next]) * 0.5 + Vector3.UP * 3.0)
        CaveGenerator._quad(wall, collars[index], collars[next], collars[next] + Vector3.DOWN * CURTAIN_M,
            collars[index] + Vector3.DOWN * CURTAIN_M, (collars[index] + collars[next]) * 0.5 + out * 3.0)


## Plan directions away from an opening along a rim chain: each point's normal to the chain (the average of
## its segments'), turned to the side [param side] (+1: right of the walking direction, -1: left).
static func rim_normals(rim: PackedVector3Array, side: float, closed: bool) -> PackedVector3Array:
    var normals := PackedVector3Array()
    for index in rim.size():
        var before := rim[(index - 1 + rim.size()) % rim.size()] if closed or index > 0 else rim[index]
        var after := rim[(index + 1) % rim.size()] if closed or index < rim.size() - 1 else rim[index]
        var tangent := Vector3(after.x - before.x, 0.0, after.z - before.z)
        var normal := Vector3(tangent.z, 0.0, -tangent.x) * side
        normals.append(normal.normalized() if normal.length_squared() > 1.0e-8 else Vector3.ZERO)
    # A point where the chain doubles back on itself borrows its nearest neighbour's direction.
    for index in normals.size():
        if normals[index] == Vector3.ZERO:
            for step in range(1, normals.size()):
                var other := normals[(index + step) % normals.size()]
                if other != Vector3.ZERO:
                    normals[index] = other
                    break
    return normals


static func _append_surface(target: Dictionary, source: Dictionary, transform: Transform3D) -> void:
    for index in source.vertices.size():
        target.vertices.append(transform * source.vertices[index])
        target.normals.append(transform.basis * source.normals[index])
        target.uvs.append(source.uvs[index])


## Smooth shading across [param surfaces] (as CaveNetworkMesher does for the network): each corner averages the
## area-weighted normals of the faces meeting at its position (to 0.1 mm) that turn less than 72° from its own:
## the steep faces of a cliff or a funnel blend, only the sharpest edges stay.
static func smooth_normals(surfaces: Array[Dictionary], crease_cos: float = 0.3) -> void:
    var weighted: Array[Vector3] = []
    var groups := {}
    var unit: Array[Vector3] = []
    for surface in surfaces:
        var vertices: PackedVector3Array = surface.vertices
        for index in range(0, vertices.size(), 3):
            var face := weighted.size()
            weighted.append(-(vertices[index + 1] - vertices[index]).cross(vertices[index + 2] - vertices[index]))
            unit.append(weighted[-1].normalized())
            for corner in 3:
                var key := vertices[index + corner].snappedf(0.0001)
                if groups.has(key):
                    (groups[key] as Array).append(face)
                else:
                    groups[key] = [face]
    var face := 0
    for surface in surfaces:
        var vertices: PackedVector3Array = surface.vertices
        var normals := PackedVector3Array()
        normals.resize(vertices.size())
        for index in range(0, vertices.size(), 3):
            var own := unit[face]
            for corner in 3:
                var sum := Vector3.ZERO
                for other: int in groups[vertices[index + corner].snappedf(0.0001)]:
                    if unit[other].dot(own) > crease_cos:
                        sum += weighted[other]
                normals[index + corner] = sum.normalized() if sum.length_squared() > 0.0 else own
            face += 1
        surface.normals = normals

## Inside an opening's own space: a porch's prism and bend, or the column of a doline, light shaft or exit
## between its floor and 2 m above the ground.
static func contains(data: PlanetData, placement: CavePlacement, point: Vector3) -> bool:
    for opening: Dictionary in placement.openings():
        var local: Vector3 = (opening.frame as Transform3D).affine_inverse() * point
        if opening.kind == "porch":
            if _in_porch(placement, opening, point):
                return true
            continue
        if absf(local.x) > float(opening.width) * 0.5 + 0.3 or local.z < -float(opening.length) - 0.3 \
                or local.z > float(opening.get("back", 0.0)) + 0.3:
            continue
        if not Geometry2D.is_point_in_polygon(Vector2(local.x, local.z), opening.polygon):
            continue
        var ground := ground_in_frame(data, opening.frame, local.x, local.z)
        if local.y >= -float(opening.floor_depth) - 0.3 and local.y <= ground.y + 2.0:
            return true
    return false

## Under the rock of an entrance: a porch's own gallery (its straight prism or its bend, not the open-air
## approach), or a doline throat or light shaft more than a metre under the ground, its bell included.
static func in_gallery(data: PlanetData, placement: CavePlacement, point: Vector3) -> bool:
    var frame := placement.surface_transform()
    var site := frame.affine_inverse() * point
    for opening: Dictionary in placement.openings():
        # The bend's presence is a capsule around its centre line: over a wide porch it reaches the open air.
        if opening.kind == "porch" and _in_porch(placement, opening, point) \
                and site.y <= ground_in_frame(data, frame, site.x, site.z).y - 1.0:
            return true
        if opening.kind in ["skylight", "light"]:
            var local: Vector3 = (opening.frame as Transform3D).affine_inverse() * point
            var reach := 0.0
            for rim: Vector2 in opening.polygon:
                reach = maxf(reach, rim.length())
            if Vector2(local.x, local.z).length() <= reach * 1.3 + 3.0 and local.y >= -float(opening.floor_depth) - 1.0 \
                    and local.y <= ground_in_frame(data, opening.frame, local.x, local.z).y - 1.0:
                return true
    return false


static func _in_porch(placement: CavePlacement, opening: Dictionary, point: Vector3) -> bool:
    var local: Vector3 = (opening.frame as Transform3D).affine_inverse() * point
    var axis: Vector2 = opening.axis
    if local.y >= axis.x - 0.3 and local.y <= axis.y + 0.3 \
            and Geometry2D.is_point_in_polygon(Vector2(local.x, local.z), opening.polygon):
        return true
    return CavePortal.in_bend(placement, placement.surface_transform().affine_inverse() * point)


## The generated roof, including its relief, stays under the terrain, and a porch's bend inside the rock.
static func site_error(data: PlanetData, placement: CavePlacement, cave: Dictionary) -> String:
    # Large authored rooms contribute hundreds of thousands of roof vertices: EVERY point is checked against
    # the same canonical terrain query (no coarser sampling or relaxed cover tolerance).
    var points := CaveGenerator.cover_points(cave)
    if roof_out(data, placement, points, 0, points.size()):
        return ROOF_OUT_ERROR
    if placement.profile.entrance_type != "shaft":
        return CavePortal.porch_error(data, placement)
    return ""


## Does a roof point of [param points] (indices [param from] to [param to] excluded) stand within 0.5 m of the
## ground or above it? The site_error test over a slice, for CaveFitter to share the points between threads.
static func roof_out(data: PlanetData, placement: CavePlacement, points: PackedVector3Array, from: int, to: int) -> bool:
    var offset := placement.network_offset
    var frame := placement.surface_transform()
    var inverse := frame.affine_inverse()
    var depth := placement.mouth_depth()
    for index in range(from, to):
        var vertex := points[index]
        var direction := (frame * Vector3(vertex.x + offset.x, 0.0, vertex.z + offset.z)).normalized()
        var ground := inverse * (direction * CaveGround.surface_dist(data, direction))
        if vertex.y - depth > ground.y - 0.5:
            return true
    return false
