class_name CaveCrawlPassage
extends RefCounted
## A short terminal branch with accurate low clearances, independent of the large-room lattice.
## Lofted sections use the same triangles for rendering, collision and containment.


static func append(mesh: Dictionary, spec: Dictionary) -> void:
    var end := (mesh.graph.bounds as AABB).end.z
    var floor_y := float(mesh.graph.tail_floor)
    var rings: Array[PackedVector3Array] = [CaveNetwork._arch(mesh.exit)]
    if rings[0].size() < 2:
        mesh.error = "Le raccord des passages bas est vide. Modifier la graine ou les dimensions."
        return
    for index in 45:
        var t := index / 44.0
        var center := Vector3(sin(t * TAU) * 1.8, floor_y - sin(t * PI) * 0.8,
            lerpf(end + 2, float(spec.length_m), t))
        var squeeze := pow(absf(sin(t * PI * int(spec.crawls))), 8)
        var width := lerpf(float(spec.width_m), 1.05, squeeze)
        var height := lerpf(float(spec.height_m), 0.8, squeeze)
        if bool(spec.exit_open):
            var blend := smoothstep(0.88, 1.0, t)
            width = lerpf(width, float(spec.exit_width_m), blend)
            height = lerpf(height, float(spec.exit_height_m), blend)
        var ring := PackedVector3Array()
        for corner in CaveGenerator.RING_SEGMENTS + 1:
            var angle := PI * corner / CaveGenerator.RING_SEGMENTS
            ring.append(center + Vector3(cos(angle) * width * 0.5, sin(angle) * height, 0))
        if index == 0:
            CaveNetwork._join_portal(mesh, mesh.exit, ring, center + Vector3(0, height * 0.4, -1))
        else:
            var previous: PackedVector3Array = rings.back()
            var inside := center + Vector3(0, height * 0.4, -0.25)
            for corner in CaveGenerator.RING_SEGMENTS:
                CaveGenerator._quad(mesh.wall, previous[corner], previous[corner + 1],
                    ring[corner + 1], ring[corner], inside)
            CaveGenerator._quad(mesh.floor, previous[-1], previous[0], ring[0], ring[-1], inside)
        rings.append(ring)
        var cover: PackedVector3Array = mesh.cover_points
        cover.append_array(ring)
        mesh.cover_points = cover
        for p in ring: mesh.bounds = (mesh.bounds as AABB).expand(p)
    if bool(spec.exit_open):
        mesh.exit_ring = rings.back()
    else:
        var last: PackedVector3Array = rings.back()
        var center: Vector3 = (last[0] + last[-1]) * 0.5
        for index in CaveGenerator.RING_SEGMENTS:
            CaveGenerator._triangle(mesh.wall, center, last[index], last[index + 1], center + Vector3.FORWARD)
    mesh.crawl_rings = rings


static func contains(rings: Array[PackedVector3Array], point: Vector3, tolerance: float) -> bool:
    if point.z < rings[0][0].z - tolerance or point.z > rings[-1][0].z + tolerance:
        return false
    for index in rings.size() - 1:
        var a := rings[index]
        var b := rings[index + 1]
        if point.z > b[0].z + 0.00001: continue
        var t := clampf(inverse_lerp(a[0].z, b[0].z, point.z), 0, 1)
        var ca := (a[0] + a[-1]) * 0.5
        var cb := (b[0] + b[-1]) * 0.5
        var center := ca.lerp(cb, t)
        var wa := (a[0].x - a[-1].x) * 0.5
        var wb := (b[0].x - b[-1].x) * 0.5
        var width := lerpf(wa, wb, t)
        if absf(point.x - center.x) > width + tolerance or point.y < center.y - tolerance:
            return false
        var f := clampf((point.x - center.x) / maxf(0.001, width), -1, 1)
        var roof := lerpf(CaveNetwork._at_x(a, ca.x + f * wa).y, CaveNetwork._at_x(b, cb.x + f * wb).y, t)
        return point.y <= roof + tolerance
    return false
