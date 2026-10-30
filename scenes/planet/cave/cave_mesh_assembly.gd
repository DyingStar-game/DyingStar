class_name CaveMeshAssembly
extends RefCounted
## CPU-only GDScript surface assembly shared by rendering and collision.


static func finish(mesh: Dictionary, graph: Dictionary) -> void:
    mesh.wall = _surface(mesh.wall_vertices)
    mesh.floor = _surface(mesh.floor_vertices)
    mesh.erase("wall_vertices")
    mesh.erase("floor_vertices")
    mesh.faces = mesh.wall.vertices.duplicate()
    mesh.faces.append_array(mesh.floor.vertices)
    var roof := {}
    var centers: Array[Vector2] = []
    if graph.has("sky"):
        centers.append(graph.sky.center)
    for light: Dictionary in graph.get("lights", []):
        centers.append(light.center)
    var loops: Array[Dictionary] = []
    for center in centers:
        loops.append({})
    for point: Vector3 in mesh.faces:
        var plan := Vector2(point.x, point.z)
        roof[plan] = maxf(float(roof.get(plan, -INF)), point.y)
        if centers.is_empty() or absf(point.y - float(mesh.top_y)) >= 1.0e-7:
            continue
        var nearest := 0
        for index in range(1, centers.size()):
            if plan.distance_squared_to(centers[index]) < plan.distance_squared_to(centers[nearest]):
                nearest = index
        loops[nearest][point] = true
    mesh.cover_points = PackedVector3Array()
    for plan: Vector2 in roof:
        mesh.cover_points.append(Vector3(plan.x, roof[plan], plan.y))
    var first := 0
    if graph.has("sky"):
        mesh.sky = _ordered(PackedVector3Array(loops[0].keys()), centers[0], true)
        first = 1
    if graph.has("lights"):
        mesh.lights = []
        for index in range(first, centers.size()):
            mesh.lights.append(_ordered(PackedVector3Array(loops[index].keys()), centers[index], true))
    for key in ["entry", "exit"]:
        var points: PackedVector3Array = mesh[key]
        var low := INF
        var high := -INF
        for point in points:
            low = minf(low, point.y)
            high = maxf(high, point.y)
        mesh[key] = _ordered(points, Vector2(0, (low + high) * 0.5)) if not points.is_empty() else points
    mesh.erase("top_y")


static func _surface(vertices: PackedVector3Array) -> Dictionary:
    var surface := CaveGenerator._empty_surface()
    surface.vertices = vertices
    var uvs := PackedVector2Array()
    uvs.resize(vertices.size())
    for index in vertices.size():
        uvs[index] = Vector2(vertices[index].x + vertices[index].y, vertices[index].z) * 0.25
    surface.uvs = uvs
    return surface


static func _ordered(points: PackedVector3Array, center: Vector2, horizontal: bool = false) -> PackedVector3Array:
    var ordered: Array[Vector3] = []
    ordered.assign(points)
    ordered.sort_custom(func(a: Vector3, b: Vector3) -> bool:
        return atan2((a.z if horizontal else a.y) - center.y, a.x - center.x) \
            < atan2((b.z if horizontal else b.y) - center.y, b.x - center.x))
    return PackedVector3Array(ordered)


## Zipper triangulation: every original boundary edge is used exactly once; no resampling of a curved seam.
static func join(mesh: Dictionary, arch: PackedVector3Array, loop: PackedVector3Array, inside: Vector3) -> void:
    var center := Vector2.ZERO
    for point in loop:
        center += Vector2(point.x, point.y)
    center /= loop.size()
    var other_center := Vector2.ZERO
    for point in arch:
        other_center += Vector2(point.x, point.y)
    other_center /= arch.size()
    var a := _ordered(arch, other_center)
    var b := _ordered(loop, center)
    var ta := _angles(a, other_center)
    var tb := _angles(b, center)
    var i := 0
    var j := 0
    # Start at the -PI cut, and close the two complete loops once.
    while i < a.size() or j < b.size():
        var pa := a[i % a.size()]
        var pb := b[j % b.size()]
        var next_a := ta[(i + 1) % a.size()] + (TAU if i + 1 >= a.size() else 0.0)
        var next_b := tb[(j + 1) % b.size()] + (TAU if j + 1 >= b.size() else 0.0)
        var third: Vector3
        if j >= b.size() or (i < a.size() and next_a <= next_b):
            third = a[(i + 1) % a.size()]
            i += 1
        else:
            third = b[(j + 1) % b.size()]
            j += 1
        var target := inside
        if is_inf(target.x):
            target = Vector3((center.x + other_center.x) * 0.5, (center.y + other_center.y) * 0.5,
                (pa.z + pb.z) * 0.5)
        var normal := -(pb - pa).cross(third - pa).normalized()
        if normal.dot(target - (pa + pb + third) / 3.0) < 0.0:
            normal = -normal
        CaveGenerator._triangle(mesh.floor if normal.y > 0.65 else mesh.wall, pa, pb, third, target)


static func _angles(points: PackedVector3Array, center: Vector2) -> PackedFloat64Array:
    var result := PackedFloat64Array()
    for point in points:
        result.append(atan2(point.y - center.y, point.x - center.x))
    return result
