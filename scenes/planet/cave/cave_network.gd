class_name CaveNetwork
extends RefCounted
## Seeded spatial graph (CaveLayoutV8) meshed by CaveNetworkMesher: volumes are unioned before meshing, so
## branches never retain internal walls.

static var _mesher: Script


static func warm() -> bool:
    if _mesher == null:
        _mesher = NativeScript.load_usable("res://scenes/planet/cave/CaveNetworkMesher.cs", ["Build", "Configure", "Sample"])
    return _mesher != null


static func layout(spec: Dictionary) -> Dictionary:
    return CaveLayoutV8.layout(spec)


static func build(spec: Dictionary) -> Dictionary:
    if _mesher == null:
        return {"error": "Le module de géométrie Dying Star doit être compilé avant de générer un réseau."}
    var graph := layout(spec)
    var sampler: RefCounted = _mesher.new()
    var mesh: Dictionary = sampler.call("Build", graph)
    if not str(mesh.error).is_empty():
        return mesh
    CaveMeshAssembly.finish(mesh, graph)
    mesh.spec = spec.duplicate(true)
    mesh.graph = graph
    mesh.sampler = sampler
    mesh.bounds = graph.bounds.merge(AABB(Vector3(-spec.entrance_width_m * 0.5, 0, 0),
        Vector3(spec.entrance_width_m, spec.entrance_height_m, graph.entry_end)))
    mesh.rings = []
    _vestibule(mesh, spec)
    CaveEntrance.smooth_normals([mesh.wall, mesh.floor], 0.5)
    return mesh


## A porch's gallery (CavePortal, built against the terrain) ends on the vestibule ring, joined here to the
## lattice's entrance; a doline has no side gallery, its open throat (mesh.sky) meets the funnel walls.
static func _vestibule(mesh: Dictionary, spec: Dictionary) -> void:
    if str(spec.entrance_type) == "shaft":
        if (mesh.get("sky", PackedVector3Array()) as PackedVector3Array).size() < 3:
            mesh.error = "La doline ne s’ouvre pas sur sa salle. Modifier la graine ou les dimensions."
            return
    else:
        var ring := PackedVector3Array()
        for point in CavePortal.vestibule_section(spec):
            ring.append(Vector3(point.x, point.y, CaveNaturalOpening.REAR_Z))
        mesh.rings.append(ring)
        _join_portal(mesh, mesh.entry, ring)
    # Version 9 light shafts: each one's open loop on the lattice's top plane, where its walls rise to the ground.
    var loops: Array = mesh.get("lights", [])
    if loops.size() != (mesh.graph.get("lights", []) as Array).size() \
            or loops.any(func(loop: PackedVector3Array): return loop.size() < 3):
        mesh.error = "Un puits de lumière ne s’ouvre pas. Modifier la graine ou le nombre de puits."
        return
    if CaveLayoutV8.has_crawls(spec):
        CaveCrawlPassage.append(mesh, spec)
    elif bool(spec.exit_open):
        mesh.exit_ring = _arch(mesh.exit)
    mesh.faces = mesh.wall.vertices.duplicate()
    mesh.faces.append_array(mesh.floor.vertices)


static func _arch(loop: PackedVector3Array) -> PackedVector3Array:
    if loop.is_empty():
        return loop
    var floor_y := INF
    for p in loop:
        floor_y = minf(floor_y, p.y)
    var points: Array[Vector3] = []
    var right := loop[0]
    var left := loop[0]
    for p in loop:
        if p.x > right.x: right = p
        if p.x < left.x: left = p
        if p.y > floor_y + 0.05: points.append(p)
    right.y = floor_y
    left.y = floor_y
    points.append(right)
    points.append(left)
    points.sort_custom(func(a: Vector3, b: Vector3): return a.x > b.x)
    return PackedVector3Array(points)


static func _join_portal(mesh: Dictionary, loop: PackedVector3Array, before: PackedVector3Array,
        interior: Vector3 = Vector3(INF, INF, INF)) -> void:
    if loop.size() < 3 or before.size() < 3:
        mesh.error = "Le raccord du réseau est vide. Modifier la graine ou les dimensions."
        return
    # Keep every boundary edge, including the floor and vertical/overhanging sides.
    CaveMeshAssembly.join(mesh, before, loop, interior)


static func _at_x(arch: PackedVector3Array, x: float) -> Vector3:
    for index in arch.size() - 1:
        if x <= arch[index].x and x >= arch[index + 1].x:
            return arch[index].lerp(arch[index + 1],
                inverse_lerp(arch[index].x, arch[index + 1].x, x) if arch[index].x != arch[index + 1].x else 0.0)
    return arch[0] if x > arch[0].x else arch[-1]


static func contains(cave: Dictionary, point: Vector3, tolerance: float) -> bool:
    if cave.has("crawl_rings") and point.z > (cave.graph.bounds as AABB).end.z:
        return CaveCrawlPassage.contains(cave.crawl_rings, point, tolerance)
    if point.z < float(cave.graph.entry_end) - 2.0:
        return false  # the porch gallery in front of the ring belongs to CaveEntrance
    if not (cave.bounds as AABB).grow(tolerance).has_point(point):
        return false
    return float(cave.sampler.call("Sample", point)) >= -maxf(tolerance, float(cave.graph.cell_m) * 0.4)
