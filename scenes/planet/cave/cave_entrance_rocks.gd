class_name CaveEntranceRocks
extends RefCounted
## Weathered outcrops on fitted openings. Plain support data stays safe for the geometry workers.


static func supports(data: PlanetData, site: CavePlacement, wall: Dictionary, exposed_walls: Array[Dictionary] = []) -> Dictionary:
    var frame := site.surface_transform()
    var openings := site.openings()
    var result := {"entrance_ground": [], "entrance_wall": [], "axes": []}
    var rng := RandomNumberGenerator.new()
    rng.seed = site.seed + 7919
    var patches := FastNoiseLite.new()
    patches.seed = site.seed + 413
    patches.frequency = 0.12
    for opening: Dictionary in openings:
        if opening.kind == "porch":
            continue  # its approach supplies the exterior rim; its wall is sampled below
        var polygon: PackedVector2Array = opening.polygon
        var local: Transform3D = frame.affine_inverse() * opening.frame
        if opening.kind in ["skylight", "light"]:
            result.axes.append(Vector2(local.origin.x, local.origin.z))
        var center := Vector2.ZERO
        for vertex in polygon:
            center += vertex
        center /= polygon.size()
        for index in polygon.size():
            var a := polygon[index]
            var b := polygon[(index + 1) % polygon.size()]
            var count := clampi(int(ceil(a.distance_to(b) / 2.0)), 1, 24)
            for step in count:
                var edge := a.lerp(b, (step + rng.randf()) / count)
                var outside := edge + (edge - center).normalized() * rng.randf_range(1.8, 6.0)
                var p := local * Vector3(outside.x, 0, outside.y)
                if patches.get_noise_2d(p.x, p.z) < -0.15:
                    continue  # bare stretches alternate with rockier patches, rather than a complete necklace
                p = CaveEntrance.ground_in_frame(data, frame, p.x, p.z)
                if _inside(openings, frame * p, 2.0):
                    continue
                var dx := CaveEntrance.ground_in_frame(data, frame, p.x + 0.3, p.z) - p
                var dz := CaveEntrance.ground_in_frame(data, frame, p.x, p.z + 0.3) - p
                var normal := dz.cross(dx).normalized()
                if normal.y > 0.72:
                    result.entrance_ground.append({"point": p, "normal": normal})
    # Area-weighted sampling avoids overpopulating the finely triangulated rim seals.
    var area := 0.0
    var broad_openings: Array[Dictionary] = openings.filter(func(opening: Dictionary): return opening.kind != "light")
    var surfaces: Array[Dictionary] = [wall]
    surfaces.append_array(exposed_walls)
    for source_index in surfaces.size():
        var surface := surfaces[source_index]
        for index in range(0, surface.vertices.size(), 3):
            var a: Vector3 = surface.vertices[index]
            var b: Vector3 = surface.vertices[index + 1]
            var c: Vector3 = surface.vertices[index + 2]
            var normal: Vector3 = (surface.normals[index] + surface.normals[index + 1] + surface.normals[index + 2]).normalized()
            var center := (a + b + c) / 3.0
            if source_index == 0 and (absf(normal.y) > 0.8 or not _inside(broad_openings, frame * (center + normal * 0.05), 0.0)):
                continue
            var ground := CaveEntrance.ground_in_frame(data, frame, center.x, center.z)
            if ground.y - center.y < 0.7:
                continue
            area += (b - a).cross(c - a).length() * 0.5
            result.entrance_wall.append({"a": a, "b": b, "c": c, "normal": normal, "area": area})
    return result


static func _inside(openings: Array[Dictionary], point: Vector3, margin: float) -> bool:
    for opening in openings:
        var p: Vector3 = (opening.frame as Transform3D).affine_inverse() * point
        if opening.has("axis") and (p.y < opening.axis.x or p.y > opening.axis.y):
            continue
        var flat := Vector2(p.x, p.z)
        var polygon: PackedVector2Array = opening.polygon
        if Geometry2D.is_point_in_polygon(flat, polygon):
            return true
        if margin > 0.0:
            for index in polygon.size():
                var near := Geometry2D.get_closest_point_to_segment(flat, polygon[index], polygon[(index + 1) % polygon.size()])
                if near.distance_to(flat) < margin:
                    return true
    return false


static func scatter(data: Dictionary, rule: Dictionary, rng: RandomNumberGenerator, budget: int) -> Array[Transform3D]:
    var result: Array[Transform3D] = []
    var candidates: Array = data.get("rock_supports", {}).get(rule.support, [])
    if candidates.is_empty():
        return result
    var embedded: bool = rule.support == "entrance_wall"
    var limit := mini(budget, rule.max_instances)
    for attempt in limit * 24:
        if result.size() >= limit:
            break
        var support: Dictionary = candidates[rng.randi_range(0, candidates.size() - 1)]
        var p: Vector3
        if embedded:
            var target := rng.randf() * float(candidates.back().area)
            var low := 0
            var high := candidates.size() - 1
            while low < high:
                var middle := (low + high) / 2
                if float(candidates[middle].area) < target:
                    low = middle + 1
                else:
                    high = middle
            support = candidates[low]
            var u := sqrt(rng.randf())
            # Separate barycentric draw, with weights summing to one.
            var v := rng.randf()
            p = support.a * (1.0 - u) + support.b * (u * v) + support.c * (u * (1.0 - v))
        else:
            p = support.point
        var normal: Vector3 = support.normal
        var scale := lerpf(rule.scale_min, rule.scale_max, pow(rng.randf(), 1.6))
        var tangent := normal.cross(Vector3.FORWARD).normalized()
        if tangent.length_squared() < 0.1:
            tangent = normal.cross(Vector3.RIGHT).normalized()
        var basis := Basis(tangent, normal, tangent.cross(normal)) * Basis(Vector3.UP, rng.randf_range(0, TAU))
        basis *= Basis.from_euler(Vector3(rng.randf_range(-0.18, 0.18), 0, rng.randf_range(-0.18, 0.18)))
        var proportions := Vector3(rng.randf_range(0.8, 1.2), rng.randf_range(0.85, 1.15), rng.randf_range(0.8, 1.2))
        basis *= Basis.from_scale(proportions * scale)
        var bounds: AABB = rule.bounds
        var burial := rng.randf_range(0.42, 0.65) if embedded else rng.randf_range(0.10, 0.24)
        var low := INF
        var high := -INF
        for corner in 8:
            var depth := (basis * bounds.get_endpoint(corner)).dot(normal)
            low = minf(low, depth)
            high = maxf(high, depth)
        var pose := Transform3D(basis, p - normal * lerpf(low, high, burial))
        var box := pose * bounds
        var clearance := Vector2(box.size.x, box.size.z).length() * 0.5 + 1.1
        if not _clear_route(data, box.get_center(), clearance):
            continue
        var separated := true
        for other in result:
            if other.origin.distance_to(pose.origin) < float(rule.spacing_m) or (other * bounds).grow(0.25).intersects(box):
                separated = false
                break
        if separated:
            result.append(pose)
    return result


static func _clear_route(data: Dictionary, point: Vector3, clearance: float) -> bool:
    for axis: Vector2 in data.get("rock_supports", {}).get("axes", []):
        if Vector2(point.x, point.z).distance_to(axis) < clearance:
            return false
    for section: Dictionary in data.get("decor_sections", []):
        var rings: Array = section.rings
        for index in rings.size() - 1:
            var a: Vector3 = (rings[index][0] + rings[index][-1]) * 0.5 + Vector3.UP
            var b: Vector3 = (rings[index + 1][0] + rings[index + 1][-1]) * 0.5 + Vector3.UP
            if point.distance_to(Geometry3D.get_closest_point_to_segment(point, a, b)) < clearance:
                return false
    return true
