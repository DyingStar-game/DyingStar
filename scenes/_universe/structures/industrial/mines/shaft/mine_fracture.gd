class_name MineFracture
extends RefCounted
## A layer of a mine face broken into blocks: the rock between the face as it stands (the gallery dug to from_m) and
## the face one layer on (dug to to_m), cut by a Voronoi diagram on each side of the layer's fault
## (CaveNetworkMesher.BuildFragments). Its outer faces are the very wall the cells show, its cracks are planes and
## the fault is one of them.
##
## Everything follows from (mine seed, gallery, layer, from_m, to_m): the client draws the blocks cracking open while
## a player drills, the server makes them rocks when the layer falls, and each rock rebuilds its own shape from those
## numbers (MineRock). Seeds never depend on the rock's densities, so a different last bit on another machine changes
## a block's surface by a hair, never which blocks there are.

## Lattice spacing (m) of the blocks: their cracks are planes, rendered exactly at any spacing; the wall's relief is
## followed to about this.
const STEP_M := 0.22
## Gap (m) the server leaves between its blocks across every crack, so two rigid bodies never start interpenetrating.
## The client draws them without one: the cracks stay shut until they open.
const BODY_GAP_M := 0.015
## A block smaller than this (m³) is dust: it shows in the wall, then never becomes a rock.
const DUST_M3 := 0.003
## When the cracks reach the farthest block, as a share of the drilling (the nearest cracks at ONSET_FIRST).
const ONSET_FIRST := 0.08
const ONSET_SPAN := 0.75


## The Voronoi sites of a layer, in the frame of its face (MineSite.face_frame at from_m): spread evenly over the
## face's quarter ellipsoid (the best of a few candidates each, by distance on it: spread over the face's outline
## instead, the sites stood far apart on its steep sides and the blocks there grew long), then set into the layer.
## {points: PackedVector3Array, sides: PackedInt32Array (1 = on the positive side of the fault)}.
static func seeds(mine_seed: int, id: int, step: int, half_width: float, height: float, layer: float,
        fault_normal: Vector2, fault_offset: float, count_min: int, count_max: int) -> Dictionary:
    var rng := RandomNumberGenerator.new()
    rng.seed = ("%d|fracture|%d|%d" % [mine_seed, id, step]).hash()
    var count := rng.randi_range(count_min, maxi(count_min, count_max))
    var taken: Array[Vector3] = []
    for k in count:
        taken.append(_best_candidate(rng, taken, half_width, height, -1, fault_normal, fault_offset))
    # Both sides of the fault need sites: a side without one would leave its part of the layer unbroken.
    for side in 2:
        var on_side := 0
        for point: Vector3 in taken:
            on_side += 1 if _side(point, fault_normal, fault_offset) == side else 0
        while on_side < 2:
            taken.append(_best_candidate(rng, taken, half_width, height, side, fault_normal, fault_offset))
            on_side += 1
    var points := PackedVector3Array()
    var sides := PackedInt32Array()
    for point: Vector3 in taken:
        # Into the rock along the gallery, to the middle of the layer give or take: the layer is the face pushed
        # back by its thickness.
        points.append(point + Vector3.FORWARD * layer * (0.5 + rng.randf_range(-0.25, 0.25)))
        sides.append(_side(point, fault_normal, fault_offset))
    return {"points": points, "sides": sides}


static func _side(point: Vector3, normal: Vector2, offset: float) -> int:
    return 1 if Vector2(point.x, point.y).dot(normal) - offset >= 0.0 else 0


## A point of the face's quarter ellipsoid (the smooth face: half width across and deep, height up) far from
## [param taken] (the best of 10 candidates); [param side] >= 0 keeps it on that side of the fault. Not on the rim:
## the layer thins to nothing there.
static func _best_candidate(rng: RandomNumberGenerator, taken: Array[Vector3], half_width: float, height: float,
        side: int, normal: Vector2, offset: float) -> Vector3:
    var best := Vector3(0.0, height * 0.5, -half_width)
    var best_gap := -1.0
    for candidate in 10:
        var point := best
        for attempt in 64:
            var theta := rng.randf_range(0.0, PI)  # round the face: 0 = right floor, PI = left floor
            # Towards the tip, uniform in area: sin(phi) uniform.
            var phi := asin(rng.randf_range(0.2, 1.0))
            point = Vector3(half_width * cos(theta) * cos(phi), height * sin(theta) * cos(phi), -half_width * sin(phi))
            if side < 0 or _side(point, normal, offset) == side:
                break
        var gap := INF
        for other: Vector3 in taken:
            gap = minf(gap, point.distance_squared_to(other))
        if gap > best_gap:
            best_gap = gap
            best = point
    return best


## When each block starts to crack, as a share of the drilling (0..1): the cracks run out from [param hit] (face
## frame), the nearest blocks first.
static func onsets(points: PackedVector3Array, hit: Vector3) -> PackedFloat32Array:
    var farthest := 0.0
    for point: Vector3 in points:
        farthest = maxf(farthest, point.distance_to(hit))
    var out := PackedFloat32Array()
    for point: Vector3 in points:
        out.append(ONSET_FIRST + ONSET_SPAN * point.distance_to(hit) / maxf(farthest, 1.0e-6))
    return out


## Everything a worker needs to break layer [param step] of gallery [param id] of [param site], standing from
## [param from_m] to [param to_m] along the gallery, with [param gap] (m) between blocks. Pure data. {} while the
## mine's plan is unknown.
static func plan(site: MineSite, id: int, step: int, from_m: float, to_m: float, gap: float) -> Dictionary:
    var layout := site.layout()
    if layout.is_empty() or id < 0 or id >= (layout.galleries as Array).size() or to_m <= from_m:
        return {}
    var s: Dictionary = layout.settings
    var half_width := float(s.gallery_width_m) * 0.5
    var height := float(s.gallery_height_m)
    var layer := to_m - from_m
    var frame := site.face_frame(id, from_m)
    var fault: Array = site.fault_of(id, step)
    # The face's quarter ellipsoid, the layer behind it and the wall's relief round both.
    var relief := float(s.wall_roughness_m) * 1.6 + 0.6
    var box := AABB(Vector3(-half_width - relief, -0.6, -(half_width + layer + relief)),
        Vector3(2.0 * (half_width + relief), height + relief + 0.6, half_width + layer + 2.0 * relief))
    var before := site.dug().duplicate()
    before[id] = from_m
    var after := before.duplicate()
    after[id] = to_m
    var near := frame * box
    var sites := seeds(site.seed, id, step, half_width, height, layer, fault[0], float(fault[1]), site.fragment_min,
        site.fragment_max)
    return {
        "key": key(id, step, from_m, to_m, gap),
        "frame": frame,
        "box": box,
        "points": sites.points,
        "sides": sites.sides,
        "fault_normal": fault[0],
        "fault_offset": float(fault[1]),
        "gap": gap,
        "before": MineLayout.graph_near(layout, before, near),
        "after": MineLayout.graph_near(layout, after, near),
    }


## The cache key of a layer's blocks.
static func key(id: int, step: int, from_m: float, to_m: float, gap: float) -> String:
    return "%d|%d|%.3f|%.3f|%.4f" % [id, step, from_m, to_m, gap]


## The blocks of [param layer_plan] (see [method plan]): one dictionary per site, in order (index, side, wall,
## wall_normals, crack, crack_normals, centroid, volume, size; mine frame). [] when the native mesher is missing.
## Any thread.
static func build(layer_plan: Dictionary) -> Array:
    if layer_plan.is_empty() or not MineMesher.warm():
        return []
    var before := MineMesher.configure(layer_plan.before)
    var after := MineMesher.configure(layer_plan.after)
    if before == null or after == null:
        return []
    return before.call("BuildFragments", after, layer_plan.frame, layer_plan.box, STEP_M, layer_plan.points,
        layer_plan.sides, layer_plan.fault_normal, layer_plan.fault_offset, layer_plan.gap)


## The visible mesh of a block, in the mine frame (the walls' triplanar texture then lines up with the cells'):
## its outer rock with [param wall_material], its cracks with [param crack_material]. Null when it is empty.
static func to_mesh(block: Dictionary, wall_material: Material, crack_material: Material) -> ArrayMesh:
    var mesh := ArrayMesh.new()
    for part: Array in [["wall", wall_material], ["crack", crack_material]]:
        var vertices: PackedVector3Array = block.get(part[0], PackedVector3Array())
        if vertices.is_empty():
            continue
        var arrays := []
        arrays.resize(Mesh.ARRAY_MAX)
        arrays[Mesh.ARRAY_VERTEX] = vertices
        arrays[Mesh.ARRAY_NORMAL] = block.get(part[0] + "_normals", PackedVector3Array())
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        if part[1] != null:
            mesh.surface_set_material(mesh.get_surface_count() - 1, part[1])
    return mesh if mesh.get_surface_count() > 0 else null


## The hull points of a block, relative to its centroid (where its body stands).
static func hull_points(block: Dictionary) -> PackedVector3Array:
    var centroid: Vector3 = block.centroid
    var out := PackedVector3Array()
    var seen := {}
    for part: String in ["wall", "crack"]:
        for vertex: Vector3 in block.get(part, PackedVector3Array()):
            # Coincident corners of neighbouring triangles once: the hull builder pays per point.
            var snapped := (vertex * 200.0).round()
            if seen.has(snapped):
                continue
            seen[snapped] = true
            out.append(vertex - centroid)
    return out
