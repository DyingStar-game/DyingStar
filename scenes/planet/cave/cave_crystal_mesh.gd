@tool
class_name CaveCrystalMesh
extends RefCounted
## Clusters of corundum crystals: hexagonal barrels (the habit of the rock's clear crystal, rocks.py
## crystal_habit "hexagonal") bulging in their middle and ending in a flat pinacoid or a pyramid.
## Flat-shaded facets, one triangle list. COLOR.r is the height along each crystal (0 at its root,
## 1 at its tip) and COLOR.g a random value per crystal; the crystal shader brightens the glow toward
## the tips with them. The origin sits on the support and +Y points away from it, the convention of
## every CaveDecorationRule mesh; the roots go BURY_M below it so a crystal never floats.
##
## Baked once into scenes/planet/cave/assets/crystal_corundum/ by tools/stargrot/bake_crystal_assets.gd:
## the game loads the .tres, it never runs this at runtime.

## Depth of every crystal's root below its support (m, before the rule's scale).
const BURY_M := 0.12

## Cluster shape per support: crystal count, length range (m), girth as a fraction of the length,
## largest tilt from +Y (deg) and the radius (m) over which the roots spread.
const KINDS := {
    "floor": {"count": [5, 9], "length": [0.5, 1.6], "girth": [0.1, 0.15], "spread_deg": 35.0, "base_m": 0.5},
    "wall": {"count": [4, 7], "length": [0.35, 1.1], "girth": [0.1, 0.15], "spread_deg": 45.0, "base_m": 0.4},
    "ceiling": {"count": [4, 7], "length": [0.3, 0.9], "girth": [0.1, 0.14], "spread_deg": 30.0, "base_m": 0.35},
}


## The cluster of [param kind] ("floor", "wall" or "ceiling") grown from [param seed].
static func cluster(kind: String, seed: int) -> ArrayMesh:
    var arrays := cluster_arrays(kind, seed)
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh


## The raw surface arrays of [method cluster] (tests compare them).
static func cluster_arrays(kind: String, seed: int) -> Array:
    var shape: Dictionary = KINDS[kind]
    var rng := RandomNumberGenerator.new()
    rng.seed = seed
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var count := rng.randi_range(shape.count[0], shape.count[1])
    for index in count:
        # The first crystal is the cluster's largest and stands nearly upright in its middle.
        var size := 1.0 if index == 0 else rng.randf_range(0.0, 1.0)
        var length: float = lerpf(shape.length[0], shape.length[1], size)
        var radius: float = length * rng.randf_range(shape.girth[0], shape.girth[1])
        var tilt := deg_to_rad(float(shape.spread_deg) * sqrt(rng.randf()) * (0.35 if index == 0 else 1.0))
        var azimuth := rng.randf_range(0.0, TAU)
        var axis := Vector3(sin(tilt) * cos(azimuth), cos(tilt), sin(tilt) * sin(azimuth))
        var root := Vector3.ZERO
        if index > 0:
            var spread := sqrt(rng.randf()) * float(shape.base_m)
            var around := rng.randf_range(0.0, TAU)
            root = Vector3(cos(around) * spread, 0.0, sin(around) * spread)
        var pointed := rng.randf() < 0.4
        _crystal(vertices, normals, colors, root, axis, length, radius, rng.randf_range(0.0, TAU),
            pointed, rng.randf())
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_COLOR] = colors
    return arrays


## One hexagonal barrel from [param root] along [param axis]: a prism barely bulging at mid-length (0.45),
## narrowing at its shoulder (0.85), then a steep pyramid tip or a flat pinacoid.
static func _crystal(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
        root: Vector3, axis: Vector3, length: float, radius: float, twist: float, pointed: bool,
        tone: float) -> void:
    var side := axis.cross(Vector3.FORWARD if absf(axis.z) < 0.9 else Vector3.RIGHT).normalized()
    var other := axis.cross(side).normalized()
    # (height along the axis, radius) of each ring; the root ring sits BURY_M under the support.
    var rings: Array[Vector2] = [
        Vector2(-BURY_M / maxf(axis.y, 0.3), radius * 0.92),
        Vector2(length * 0.45, radius),
        Vector2(length * 0.85, radius * 0.9),
    ]
    if not pointed:
        rings.append(Vector2(length * 0.93, radius * 0.62))
    var points: Array[PackedVector3Array] = []
    for ring in rings:
        var loop := PackedVector3Array()
        for corner in 6:
            var angle := twist + TAU * corner / 6.0
            loop.append(root + axis * ring.x + (side * cos(angle) + other * sin(angle)) * ring.y)
        points.append(loop)
    var tone_of := func(h: float) -> Color: return Color(clampf(h / length, 0.0, 1.0), tone, 1.0, 1.0)
    for level in points.size() - 1:
        var low: PackedVector3Array = points[level]
        var high: PackedVector3Array = points[level + 1]
        for corner in 6:
            var next := (corner + 1) % 6
            var centre := root + axis * (rings[level].x + rings[level + 1].x) * 0.5
            var cl: Color = tone_of.call(rings[level].x)
            var ch: Color = tone_of.call(rings[level + 1].x)
            _triangle(vertices, normals, colors, centre, [low[corner], low[next], high[next]], [cl, cl, ch])
            _triangle(vertices, normals, colors, centre, [low[corner], high[next], high[corner]], [cl, ch, ch])
    var top: PackedVector3Array = points[-1]
    var top_h: float = rings[-1].x
    var inner := root + axis * (top_h - radius)
    if pointed:
        var apex := root + axis * length
        for corner in 6:
            _triangle(vertices, normals, colors, inner, [top[corner], top[(corner + 1) % 6], apex],
                [tone_of.call(top_h), tone_of.call(top_h), tone_of.call(length)])
    else:
        var tip: Color = tone_of.call(length)
        for corner in range(1, 5):
            _triangle(vertices, normals, colors, inner, [top[0], top[corner], top[corner + 1]], [tip, tip, tip])


## One flat-shaded triangle facing away from [param inside] (Godot's front faces wind clockwise).
static func _triangle(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
        inside: Vector3, corners: Array, tones: Array) -> void:
    var a: Vector3 = corners[0]
    var b: Vector3 = corners[1]
    var c: Vector3 = corners[2]
    var normal := (c - a).cross(b - a).normalized()
    var ta: Color = tones[0]
    var tb: Color = tones[1]
    var tc: Color = tones[2]
    if normal.dot((a + b + c) / 3.0 - inside) < 0.0:
        normal = -normal
        var swap := b
        b = c
        c = swap
        var tone_swap := tb
        tb = tc
        tc = tone_swap
    vertices.append_array([a, b, c])
    normals.append_array([normal, normal, normal])
    colors.append_array([ta, tb, tc])
