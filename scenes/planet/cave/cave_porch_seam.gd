class_name CavePorchSeam
extends RefCounted
## The clipped cliff is a piecewise planar mesh, not the analytic height field.
## Keep its intersection vertices in the gallery, so both sides share the same boundary.


static func refine(approach: Dictionary, arch: PackedVector2Array, rims: Array[float],
        section: PackedVector2Array, axes: Dictionary) -> Dictionary:
    var cuts: Array[Dictionary] = []
    for index in arch.size() - 1:
        cuts.append({0.0: rims[index], 1.0: rims[index + 1]})
    for surface: Dictionary in [approach.wall, approach.floor]:
        for point: Vector3 in surface.vertices:
            var flat := Vector2(point.x, point.dot(axes.up))
            for index in arch.size() - 1:
                var edge := arch[index + 1] - arch[index]
                var t := (flat - arch[index]).dot(edge) / maxf(edge.length_squared(), 1.0e-12)
                if t < -1.0e-7 or t > 1.0000001:
                    continue
                t = clampf(t, 0.0, 1.0)
                if flat.distance_to(arch[index].lerp(arch[index + 1], t)) > 1.0e-6:
                    continue
                var at := point.dot(axes.forward)
                # Ignore the terrain rim seal and any far intersections behind the mouth.
                if absf(at - lerpf(rims[index], rims[index + 1], t)) < 3.0:
                    cuts[index][snappedf(t, 1.0e-9)] = at
    var refined := PackedVector2Array()
    var refined_rims: Array[float] = []
    var refined_section := PackedVector2Array()
    for index in cuts.size():
        var keys: Array = cuts[index].keys()
        keys.sort()
        for value: float in keys:
            if value == 1.0 and index < cuts.size() - 1:
                continue
            refined.append(arch[index].lerp(arch[index + 1], value))
            refined_rims.append(cuts[index][value])
            refined_section.append(section[index].lerp(section[index + 1], value))
    return {"arch": refined, "rims": refined_rims, "section": refined_section}
