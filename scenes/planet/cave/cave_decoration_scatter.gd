class_name CaveDecorationScatter
extends RefCounted
## Seeded support-aware art placement. Pure cave-local data; no scene, physics world or UI dependency.


static func network(data: Dictionary, rule: Dictionary, rng: RandomNumberGenerator,
        budget: int) -> Array[Transform3D]:
    var result: Array[Transform3D] = []
    var candidates: Array[Dictionary] = []
    var entrance := Vector3(0, 0, float(data.graph.entry_end))
    var farthest := 1.0
    for room: Dictionary in data.graph.rooms:
        farthest = maxf(farthest, (room.a as Vector3).distance_to(entrance))
    for room: Dictionary in data.graph.rooms:
        var progress := (room.a as Vector3).distance_to(entrance) / farthest
        if not _zone(rule.zone, progress):
            continue
        var area := PI * float(room.size.x) * float(room.size.z)
        var count := clampi(int(ceil(area / (rule.spacing_m * rule.spacing_m) * 6.0)), 12, 120)
        var clusters: Array[Vector3] = []
        for cluster in 3:
            var angle := rng.randf_range(0, TAU)
            clusters.append(room.a + Basis(Vector3.UP, float(room.get("yaw", 0.0))) * Vector3(
                cos(angle) * room.size.x * 0.78, 0, sin(angle) * room.size.z * 0.78))
        for index in count:
            var angle := rng.randf_range(0, TAU)
            var point: Vector3
            if rule.distribution == "clustered":
                point = clusters[index % clusters.size()] + Vector3(cos(angle), 0, sin(angle)) * rng.randf_range(0.1, 2.5)
            else:
                var reach := sqrt(rng.randf_range(0.25, 0.8))
                point = room.a + Basis(Vector3.UP, float(room.get("yaw", 0.0))) * Vector3(
                    cos(angle) * room.size.x * reach, 0, sin(angle) * room.size.z * reach)
            candidates.append({"point": point, "room": room})
    # Rubble and blocks can also occupy the sides of galleries, never their central route.
    if rule.zone in ["all", "entrance"]:
        for link: Dictionary in data.graph.links:
            var points: Array = link.points
            for index in range(1, points.size()):
                var point: Vector3 = (points[index - 1] + points[index]) * 0.5
                if not _zone(rule.zone, point.distance_to(entrance) / farthest):
                    continue
                var tangent: Vector3 = (points[index] - points[index - 1]).normalized()
                var side := tangent.cross(Vector3.UP).normalized()
                point += side * float(link.width) * rng.randf_range(0.32, 0.42) * (-1 if rng.randf() < 0.5 else 1)
                candidates.append({"point": point, "room": {"kind": "room", "a": point, "b": point,
                    "size": Vector3(link.width, link.height, link.width), "tilt": Vector2.ZERO}})
    # Seeded shuffle prevents the first chamber consuming the whole library budget.
    for index in range(candidates.size() - 1, 0, -1):
        var other := rng.randi_range(0, index)
        var swap := candidates[index]
        candidates[index] = candidates[other]
        candidates[other] = swap
    var occupied: Array[AABB] = []
    for candidate in candidates:
        if result.size() >= mini(budget, rule.max_instances):
            break
        var scale := rng.randf_range(rule.scale_min, rule.scale_max)
        var point: Vector3 = candidate.point
        if near_path(data.graph.links, point, rule.radius_m * scale + 1.0):
            continue
        var height := surface(data.sampler, candidate.room, point, rule.support == "ceiling")
        if not is_finite(height):
            continue
        point.y = height
        var normal := _normal(data.sampler, point)
        var expected := Vector3.DOWN if rule.support == "ceiling" else Vector3.UP
        if normal.dot(expected) < cos(deg_to_rad(rule.max_slope_deg)):
            continue
        var direction := normal if rule.align_to_surface else expected
        var basis := Basis(Quaternion(Vector3.UP, direction)) * Basis(Vector3.UP, rng.randf_range(0, TAU))
        basis = basis.scaled(Vector3.ONE * scale)
        var transform := Transform3D(basis, point - direction * (rule.bounds as AABB).position.y * scale)
        var fits := true
        for corner in 8:
            var probe := transform * (rule.bounds as AABB).get_endpoint(corner) + normal * 0.16
            if float(data.sampler.call("Sample", probe)) < -0.2:
                fits = false
                break
        if fits and _separated(transform, rule, occupied):
            result.append(transform)
    return result


## Porch supports are the actual authored rings, including their descent and curved connection.
static func porch(data: Dictionary, rule: Dictionary, rng: RandomNumberGenerator,
        budget: int) -> Array[Transform3D]:
    var result: Array[Transform3D] = []
    if rule.zone not in ["all", "entrance"]:
        return result
    var occupied: Array[AABB] = []
    for section: Dictionary in data.decor_sections:
        var rings: Array = section.rings
        for attempt in mini(256, rings.size() * 4):
            if result.size() >= mini(budget, rule.max_instances):
                return result
            var index := rng.randi_range(1, rings.size() - 1)
            var a: PackedVector3Array = rings[index - 1]
            var b: PackedVector3Array = rings[index]
            var t := rng.randf()
            var left := a[-1].lerp(b[-1], t)
            var right := a[0].lerp(b[0], t)
            var width := left.distance_to(right)
            var scale := rng.randf_range(rule.scale_min, rule.scale_max)
            var radius: float = rule.radius_m * scale
            if width * 0.5 < 1.0 + radius * 2.0:
                continue
            var across := (right - left).normalized()
            var forward := ((b[0] + b[-1]) - (a[0] + a[-1])).normalized()
            var normal := forward.cross(across).normalized()
            if normal.y < 0:
                normal = -normal
            var offset := rng.randf_range(1.0 + radius, width * 0.5 - radius)
            var point := (left + right) * 0.5 + across * offset * (-1 if rng.randf() < 0.5 else 1)
            if rule.support == "ceiling":
                var roof := rng.randi_range(6, a.size() - 7)
                point = a[roof].lerp(b[roof], t)
                normal = Vector3.DOWN
                if point.y - ((left + right) * 0.5).y < (rule.bounds as AABB).size.y * scale + 2.4:
                    continue
            elif normal.dot(Vector3.UP) < cos(deg_to_rad(rule.max_slope_deg)):
                continue
            var direction := normal if rule.align_to_surface else (Vector3.DOWN if rule.support == "ceiling" else Vector3.UP)
            var basis := (Basis(Quaternion(Vector3.UP, direction)) * Basis(Vector3.UP, rng.randf_range(0, TAU))).scaled(Vector3.ONE * scale)
            var transform := Transform3D(basis, point - direction * (rule.bounds as AABB).position.y * scale)
            if _separated(transform, rule, occupied):
                result.append(transform)
    return result


static func _separated(transform: Transform3D, rule: Dictionary, occupied: Array[AABB]) -> bool:
    var box := (transform * (rule.bounds as AABB)).grow(0.08)
    for other in occupied:
        if box.intersects(other):
            return false
    occupied.append(box)
    return true


static func _zone(zone: String, progress: float) -> bool:
    match zone:
        "entrance": return progress <= 0.3
        "chamber": return progress > 0.15
        "deep": return progress >= 0.55
        _: return true


static func _normal(sampler: RefCounted, point: Vector3) -> Vector3:
    var gradient := Vector3.ZERO
    for axis in 3:
        var offset := Vector3.ZERO
        offset[axis] = 0.15
        gradient[axis] = float(sampler.call("Sample", point + offset)) - float(sampler.call("Sample", point - offset))
    return gradient.normalized()


static func surface(sampler: RefCounted, room: Dictionary, point: Vector3, ceiling: bool) -> float:
    var bounds := CaveLayoutV8._support(room)
    var air := Vector3(point.x, (room.a as Vector3).y + float(room.size.y) * 0.4, point.z)
    if float(sampler.call("Sample", air)) <= 0:
        return INF
    var direction := 1.0 if ceiling else -1.0
    var limit := bounds.end.y if ceiling else bounds.position.y
    var steps := mini(1024, int(ceil(absf(limit - air.y) / 0.25)) + 1)
    for step in steps:
        var solid := air + Vector3.UP * direction * 0.25
        if float(sampler.call("Sample", solid)) <= 0:
            for refinement in 6:
                var midpoint := (air + solid) * 0.5
                if float(sampler.call("Sample", midpoint)) > 0:
                    air = midpoint
                else:
                    solid = midpoint
            return (air.y + solid.y) * 0.5
        air = solid
    return INF


static func near_path(links: Array, point: Vector3, clearance: float) -> bool:
    for link: Dictionary in links:
        var points: Array = link.points
        for index in points.size() - 1:
            var closest := Geometry3D.get_closest_point_to_segment(point, points[index], points[index + 1])
            if point.distance_to(closest) < clearance:
                return true
    return false
