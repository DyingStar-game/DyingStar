class_name CaveNaturalOpening
extends RefCounted
## A network's open exit: one deterministic contour shared by the terrain cut, exposed rock, floor and
## containment. REAR_Z is also where a porch's vestibule ring joins the network.

const REAR_Z := 14.0


## An exit at the network's far end: an asymmetrical weathered bowl. Convexity is intentional: the same
## boundary drives exact mesh AND collider clipping.
static func outline(spec: Dictionary) -> PackedVector2Array:
    var width := float(spec.exit_width_m)
    var phase := float(int(spec.seed) % 997) * 0.031 + 2.0
    var length := minf(maxf(5.0, width * 0.8), maxf(8.0, float(spec.shaft_length_m)))
    var points := PackedVector2Array()
    for index in 49:
        var t := PI * index / 48.0
        var skew := sin(t) * sin(t) * width * 0.07 * sin(phase)
        var x := cos(t) * width * 0.5 + skew
        var z := -sin(t) * length * (1.0 + 0.1 * cos(t * 2 + phase))
        points.append(Vector2(x, z))
    for index in range(1, 32):
        var t := PI * index / 32.0
        points.append(Vector2(-cos(t) * width * 0.5,
            sin(t) * width * (0.23 + 0.035 * sin(t + phase))))
    var hull := Geometry2D.convex_hull(points)
    hull.resize(hull.size() - 1)
    return hull

static func floor_surface(polygon: PackedVector2Array, depth: float = 0.0, z_offset: float = 0.0) -> Dictionary:
    var floor := CaveGenerator._empty_surface()
    # Behind the neck the network already owns the floor; avoid overlapping faces.
    var front := PackedVector2Array()
    for p in polygon:
        if p.y <= 0.00001: front.append(p)
    polygon = front
    var center := Vector3.ZERO
    for p in polygon:
        center += Vector3(p.x, -depth, p.y + z_offset)
    center /= polygon.size()
    # Talus and uneven deposits, with exact shared boundary heights at the walls
    # and neck. No graded path is imposed across this floor.
    for index in polygon.size():
        var a := Vector3(polygon[index].x, -depth, polygon[index].y + z_offset)
        var next := (index + 1) % polygon.size()
        var b := Vector3(polygon[next].x, -depth, polygon[next].y + z_offset)
        var previous_a := center
        var previous_b := center
        for band in range(1, 5):
            var t := band / 4.0
            var pa := center.lerp(a, t)
            var pb := center.lerp(b, t)
            pa.y += sin(PI * t) * (1.1 + 0.7 * sin(index * 1.7))
            pb.y += sin(PI * t) * (1.1 + 0.7 * sin(next * 1.7))
            if band == 1:
                CaveGenerator._triangle(floor, center, pa, pb, center + Vector3.UP * 10)
            else:
                CaveGenerator._quad(floor, previous_a, pa, pb, previous_b, center + Vector3.UP * 10)
            previous_a = pa
            previous_b = pb
    return floor


static func build(data: PlanetData, opening: Dictionary, roof: PackedVector3Array) -> Dictionary:
    var wall := CaveGenerator._empty_surface()
    var polygon: PackedVector2Array = opening.polygon
    var depth := float(opening.floor_depth)
    var center := Vector2.ZERO
    for point in polygon: center += point
    center /= polygon.size()
    for index in polygon.size():
        var a := polygon[index]
        var b := polygon[(index + 1) % polygon.size()]
        if a.y >= -0.001 and b.y >= -0.001:
            continue  # rear arch is the opening into the underground cavity
        var ga := CaveEntrance.ground_in_frame(data, opening.frame, a.x, a.y)
        var gb := CaveEntrance.ground_in_frame(data, opening.frame, b.x, b.y)
        var previous_a := Vector3(a.x, -depth, a.y)
        var previous_b := Vector3(b.x, -depth, b.y)
        for band in range(1, 7):
            var t := float(band) / 6.0
            # Recessed, uneven rock faces; the top rim remains exactly on the terrain cut.
            var recess_a := sin(PI * t) * (1.1 + 0.9 * sin(index * 1.7 + t * 9.0))
            var recess_b := sin(PI * t) * (1.1 + 0.9 * sin(((index + 1) % polygon.size()) * 1.7 + t * 9.0))
            var pa := Vector3(a.x, lerpf(-depth, ga.y, t), a.y)
            var pb := Vector3(b.x, lerpf(-depth, gb.y, t), b.y)
            pa += Vector3(a.x - center.x, 0, a.y - center.y).normalized() * recess_a
            pb += Vector3(b.x - center.x, 0, b.y - center.y).normalized() * recess_b
            CaveGenerator._quad(wall, previous_a, previous_b, pb, pa, Vector3(center.x, -depth * 0.5, center.y))
            previous_a = pa
            previous_b = pb
    # Merge both sets of vertices so the curved rim and the underground arch share
    # exact edges, without a straight surface trench or cracks at the junction.
    var rear: Array[Vector3] = []
    for p in polygon:
        if p.y >= -0.001: rear.append(Vector3(p.x, 0, p.y))
    rear.sort_custom(func(a: Vector3, b: Vector3): return a.x < b.x)
    var arch: Array[Vector3] = []
    arch.assign(roof)
    arch.sort_custom(func(a: Vector3, b: Vector3): return a.x < b.x)
    var xs: Array[float] = []
    for p in rear + arch:
        if not xs.has(p.x): xs.append(p.x)
    xs.sort()
    for index in xs.size() - 1:
        var a := _at_x(arch, xs[index]) + Vector3.DOWN * depth
        var b := _at_x(arch, xs[index + 1]) + Vector3.DOWN * depth
        var ra := _at_x(rear, xs[index])
        var rb := _at_x(rear, xs[index + 1])
        var ga := CaveEntrance.ground_in_frame(data, opening.frame, ra.x, ra.z)
        var gb := CaveEntrance.ground_in_frame(data, opening.frame, rb.x, rb.z)
        var previous_a := a
        var previous_b := b
        for band in range(1, 9):
            var t := band / 8.0
            var pa := a.lerp(ga, t)
            var pb := b.lerp(gb, t)
            pa.z += sin(PI * t) * (0.6 + 0.35 * sin(a.x * 0.7 + t * 11))
            pb.z += sin(PI * t) * (0.6 + 0.35 * sin(b.x * 0.7 + t * 11))
            CaveGenerator._quad(wall, previous_a, previous_b, pb, pa, Vector3(0, -depth + 1, -1))
            previous_a = pa
            previous_b = pb
    # The whole rim (front walls and rear arch both end on the ground at the outline) sealed to the terrain
    # shown around it (CaveEntrance.seal_rim).
    var rim := PackedVector3Array()
    var outward := PackedVector3Array()
    var lift := PackedFloat32Array()
    for point in polygon:
        rim.append(Vector3(point.x, CaveEntrance.ground_in_frame(data, opening.frame, point.x, point.y).y, point.y))
        outward.append(Vector3(point.x - center.x, 0.0, point.y - center.y).normalized())
        lift.append(1.0)
    CaveEntrance.seal_rim(data, opening.frame, rim, outward, lift, true, wall)
    return {"wall": wall, "floor": floor_surface(polygon, depth)}


static func _at_x(points: Array[Vector3], x: float) -> Vector3:
    for index in points.size() - 1:
        var a := points[index]
        var b := points[index + 1]
        if x <= b.x:
            return a.lerp(b, clampf((x - a.x) / maxf(0.000001, b.x - a.x), 0, 1))
    return points.back()
