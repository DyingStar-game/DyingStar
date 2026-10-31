class_name CaveTerrainCut
extends RefCounted
## Subtract the entrance contour from triangles, including triangles much
## larger than the opening. Clipping preserves interpolated visual attributes.
## No collapsed vertices, LOD-dependent holes or separate physics approximation.


static func _pieces(poly: Array, half_width: float, length_m: float, outline: PackedVector2Array = PackedVector2Array(),
        axis: Vector2 = Vector2.ZERO, capped: bool = false, parts: Array = []) -> Array:
    var kept: Array = []
    var remainder := poly
    if not parts.is_empty():
        # Concave (eroded) outline: remove each convex part in turn from whatever the previous ones left.
        # The parts tile the outline exactly, so the union of their prisms is the outline's prism.
        if capped:
            var before := _clip_axis(remainder, axis.x, false)
            if before.size() >= 3:
                kept.append(before)  # outside the caps: never cut
            remainder = _clip_axis(remainder, axis.x, true)
            var beyond := _clip_axis(remainder, axis.y, true)
            if beyond.size() >= 3:
                kept.append(beyond)
            remainder = _clip_axis(remainder, axis.y, false)
        var pending: Array = [remainder] if remainder.size() >= 3 else []
        for part: PackedVector2Array in parts:
            var next: Array = []
            for piece: Array in pending:
                next.append_array(_pieces(piece, half_width, length_m, part))
            pending = next
        kept.append_array(pending)
        return kept
    if capped:
        # Version 8 porches bore along the frame's Y: only the stretch between both caps is removed,
        # never the far side of the hill the same prism would otherwise pierce.
        var before := _clip_axis(remainder, axis.x, false)
        if before.size() >= 3:
            kept.append(before)
        remainder = _clip_axis(remainder, axis.x, true)
        var beyond := _clip_axis(remainder, axis.y, true)
        if beyond.size() >= 3:
            kept.append(beyond)
        remainder = _clip_axis(remainder, axis.y, false)
        if remainder.size() < 3:
            return kept
    for plane in _planes(half_width, length_m, outline):
        if remainder.size() < 3:
            break
        var outside := _clip(remainder, plane, false)
        if outside.size() >= 3:
            kept.append(outside)
        remainder = _clip(remainder, plane, true)
    return kept


## The inward planes of one convex region ([method _distance] >= 0 inside): [param outline], or the
## [param half_width] × [param length_m] rectangle in front of the frame.
static func _planes(half_width: float, length_m: float, outline: PackedVector2Array) -> Array[Vector3]:
    var planes: Array[Vector3] = [Vector3(1.0, 0.0, half_width), Vector3(-1.0, 0.0, half_width),
        Vector3(0.0, 1.0, length_m), Vector3(0.0, -1.0, 0.0)]
    if not outline.is_empty():
        planes.clear()
        var center := Vector2.ZERO
        for point in outline: center += point
        center /= outline.size()
        for index in outline.size():
            var a := outline[index]
            var delta := outline[(index + 1) % outline.size()] - a
            var normal := Vector2(-delta.y, delta.x).normalized()
            if normal.dot(center - a) < 0: normal = -normal
            planes.append(Vector3(normal.x, normal.y, -normal.dot(a)))
    return planes


static func _clip(poly: Array, plane: Vector3, inside: bool) -> Array:
    var out: Array = []
    var previous: Array = poly.back()
    var previous_dist := _distance(previous[0], plane)
    var previous_in := previous_dist >= 0.0 if inside else previous_dist <= 0.0
    for current: Array in poly:
        var dist := _distance(current[0], plane)
        var current_in := dist >= 0.0 if inside else dist <= 0.0
        if current_in != previous_in:
            var t := previous_dist / (previous_dist - dist)
            var vertex: Array = []
            for index in current.size():
                vertex.append(previous[index].lerp(current[index], t))
            out.append(vertex)
        if current_in:
            out.append(current)
        previous = current
        previous_dist = dist
        previous_in = current_in
    return out


static func _distance(point: Vector3, plane: Vector3) -> float:
    return point.x * plane.x + point.z * plane.y + plane.z


## Same contract as _clip with the frame's Y as the only coordinate: [param above] keeps y >= [param level].
static func _clip_axis(poly: Array, level: float, above: bool) -> Array:
    var out: Array = []
    var previous: Array = poly.back()
    var previous_dist: float = (previous[0] as Vector3).y - level
    var previous_in := previous_dist >= 0.0 if above else previous_dist <= 0.0
    for current: Array in poly:
        var dist: float = (current[0] as Vector3).y - level
        var current_in := dist >= 0.0 if above else dist <= 0.0
        if current_in != previous_in:
            var t := previous_dist / (previous_dist - dist)
            var vertex: Array = []
            for index in current.size():
                vertex.append(previous[index].lerp(current[index], t))
            out.append(vertex)
        if current_in:
            out.append(current)
        previous = current
        previous_dist = dist
        previous_in = current_in
    return out


static func _overlaps(points: Array, half_width: float, length_m: float, back: float = 0.0,
        axis: Vector2 = Vector2(-1000.0, 1000.0)) -> bool:
    var box := AABB(points[0][0], Vector3.ZERO)
    for vertex: Array in points:
        box = box.expand(vertex[0])
    # Restrict the cut to the local surface shell, sparing the opposite hemisphere.
    return box.position.x <= half_width and box.end.x >= -half_width \
        and box.position.z <= back and box.end.z >= -length_m \
        and box.position.y < axis.y and box.end.y > axis.x


## Prism range along the opening frame's Y: the porch caps, or the historical ±1000 m surface shell.
static func _axis(opening: Dictionary) -> Vector2:
    return opening.get("axis", Vector2(-1000.0, 1000.0))


## Cut edge on the relief. The terrain shown is a mesh of ~25 m cells over a finer relief and clipping keeps its
## interpolated heights, so the cut edge stood up to ~0.5 m off the cave's rim, which is built on the exact relief
## (CaveEntrance.ground_in_frame); a 0.6 m lip hid the slit, a kerb round every opening (2026-10-31). Every vertex
## a cut leaves on an opening's outline now moves onto that relief, and the ground meets the rim; the other
## vertices of the cut triangles follow, less and less, up to SNAP_FADE_M from the outline (the clipping leaves
## some a few centimetres from the edge, which would otherwise raise the ground right back up). On the finest grid
## the cells round an opening are refined first (CaveRefine), so this only takes up what the ~3 m sub-cells miss.
## Returns what [method _triangles] needs, or {} when the edge stays as clipped: an opening not cut straight down
## (a porch bored into its approach's cliff) or a chunk whose cells ([param cell_m]) exceed SNAP_MAX_CELL_M: a
## coarse chunk, seen from afar, lies tens of metres off the relief on a mountain, and its edge pulled onto the
## relief rose as a spike through the cave's mouth (2026-10-31). Near such a porch ([param porches], its cave's) the ground
## stays as clipped, PORCH_CLEAR_M around it: moved, it rose into the mouth (a hangar on a slope, 2026-10-31).
const SNAP_FADE_M := 4.0
const PORCH_CLEAR_M := 2.0
const SNAP_MAX_CELL_M := 30.0


static func _snap(opening: Dictionary, data: PlanetData, cell_m: float, porches: Array = []) -> Dictionary:
    if data == null or cell_m > SNAP_MAX_CELL_M or opening.has("axis"):
        return {}
    var frame: Transform3D = opening.frame
    if frame.basis.y.normalized().dot(frame.origin.normalized()) < 0.999:
        return {}
    var half := float(opening.width) * 0.5
    var regions: Array = []
    for part: PackedVector2Array in opening.get("parts", []):
        regions.append(_planes(half, float(opening.length), part))
    if regions.is_empty():
        regions.append(_planes(half, float(opening.length), opening.get("polygon", PackedVector2Array())))
    var clear: Array = []
    for porch: Dictionary in porches:
        var parts: Array = porch.get("parts", [])
        var porch_regions: Array = []
        for part: PackedVector2Array in parts if not parts.is_empty() else [porch.get("polygon", PackedVector2Array())]:
            porch_regions.append(_planes(float(porch.width) * 0.5, float(porch.length), part))
        clear.append({"to_porch": (porch.frame as Transform3D).affine_inverse() * frame, "regions": porch_regions,
            "axis": _axis(porch)})
    return {"data": data, "frame": frame, "regions": regions,
        "outline": opening.get("polygon", PackedVector2Array()), "clear": clear}


## How much of its shift a vertex at [param position] (opening frame) takes: none on a bored porch's prism, all
## from PORCH_CLEAR_M away (the distance from a convex prism, through its farthest plane, bounds the true one).
static func _porch_weight(position: Vector3, snap: Dictionary) -> float:
    var nearest := INF
    for porch: Dictionary in snap.clear:
        var local: Vector3 = (porch.to_porch as Transform3D) * position
        var axis: Vector2 = porch.axis
        for planes: Array in porch.regions:
            var outside := maxf(axis.x - local.y, local.y - axis.y)
            for plane: Vector3 in planes:
                outside = maxf(outside, -_distance(local, plane))
            nearest = minf(nearest, maxf(outside, 0.0))
    return 1.0 if nearest == INF else smoothstep(0.0, PORCH_CLEAR_M, nearest)


## Whether a vertex kept by the cut lies on the removed region's outline (it is outside or on every region).
static func _on_outline(point: Vector3, regions: Array) -> bool:
    for planes: Array in regions:
        var inside := true
        for plane: Vector3 in planes:
            if _distance(point, plane) < -0.001:
                inside = false
                break
        if inside:
            return true
    return false


## How far (m) the vertex at [param position] moves to meet the relief, faded out SNAP_FADE_M from the outline.
static func _fade_shift(position: Vector3, snap: Dictionary) -> Vector3:
    var outline: PackedVector2Array = snap.outline
    var plan := Vector2(position.x, position.z)
    var distance := INF
    for index in outline.size():
        distance = minf(distance, plan.distance_to(
            Geometry2D.get_closest_point_to_segment(plan, outline[index], outline[(index + 1) % outline.size()])))
    if outline.is_empty() or distance >= SNAP_FADE_M:
        return Vector3.ZERO
    var weight := (1.0 - smoothstep(0.0, SNAP_FADE_M, distance)) * _porch_weight(position, snap)
    if weight <= 0.0:
        return Vector3.ZERO
    var ground := CaveEntrance.ground_in_frame(snap.data, snap.frame, position.x, position.z)
    return (ground - position) * weight


## Where [param point] lies along the segment [param a] → [param b] (0..1, ends excluded), or -1 off it.
static func _along(a: Vector3, b: Vector3, point: Vector3) -> float:
    var ab := b - a
    var length_sq := ab.length_squared()
    if length_sq < 1.0e-12 or point.distance_squared_to(a) < 1.0e-12 or point.distance_squared_to(b) < 1.0e-12:
        return -1.0
    var t := (point - a).dot(ab) / length_sq
    if t <= 0.0 or t >= 1.0 or (a + ab * t).distance_squared_to(point) > 1.0e-8:
        return -1.0
    return t


## One cut triangle ([param poly], opening frame) as triangles from its [param pieces]: fanned as clipped, or,
## with [param snap], with the outline's vertices on the relief and the others near it following (_fade_shift).
## Moving them must open no slit:
## - inside the triangle, the pieces' T-junctions (a piece edge running past another piece's vertex, harmless
##   while everything stayed in the triangle's plane) get that vertex, and a moved piece is fanned from its centre;
## - the triangle's corners stay put, and a vertex on its edges, shared with a neighbour cut the same way, moves
##   by the shift interpolated along the edge between the corners and its outline crossings, which both share.
static func _triangles(poly: Array, pieces: Array, snap: Dictionary) -> Array:
    var result: Array = []
    if snap.is_empty():
        for piece: Array in pieces:
            _fan(piece, result)
        return result
    var vertices: Dictionary = {}  # position -> vertex
    for piece: Array in pieces:
        for vertex: Array in piece:
            vertices[vertex[0]] = vertex
    var shift: Dictionary = {}  # position -> displacement, opening frame
    for position: Vector3 in vertices:
        if _on_outline(position, snap.regions):
            var weight := _porch_weight(position, snap)
            if weight > 0.0:
                shift[position] = (CaveEntrance.ground_in_frame(snap.data, snap.frame, position.x, position.z)
                    - position) * weight
    if shift.is_empty():
        for piece: Array in pieces:
            _fan(piece, result)
        return result
    var fixed: Dictionary = {}  # corners and edge vertices: moved only along their edge's knots
    for corner: Array in poly:
        fixed[corner[0]] = true
    for edge in 3:
        var a: Vector3 = poly[edge][0]
        var b: Vector3 = poly[(edge + 1) % 3][0]
        var knots: Array = [[0.0, Vector3.ZERO], [1.0, Vector3.ZERO]]
        for position: Vector3 in vertices:
            var t := _along(a, b, position)
            if t <= 0.0:
                continue
            if shift.has(position):
                knots.append([t, shift[position]])
            else:
                fixed[position] = true
        if knots.size() == 2:
            continue
        knots.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
        for position: Vector3 in vertices:
            var t := _along(a, b, position)
            if t <= 0.0 or shift.has(position):
                continue
            for index in range(1, knots.size()):
                if t <= knots[index][0]:
                    var span: float = knots[index][0] - knots[index - 1][0]
                    var weight := 0.0 if span <= 0.0 else (t - float(knots[index - 1][0])) / span
                    shift[position] = (knots[index - 1][1] as Vector3).lerp(knots[index][1], weight)
                    break
    for position: Vector3 in vertices:
        if not shift.has(position) and not fixed.has(position):
            var fade := _fade_shift(position, snap)
            if fade != Vector3.ZERO:
                shift[position] = fade
    # Every piece edge runs along a clipping line or a side of the triangle: index the vertices by the lines they
    # lie on, and look for a T-junction only among the vertices of the edge's own line.
    var lines: Array[Vector3] = []
    for planes: Array in snap.regions:
        lines.append_array(planes)
    for edge in 3:
        var a: Vector3 = poly[edge][0]
        var b: Vector3 = poly[(edge + 1) % 3][0]
        var normal := Vector2(b.z - a.z, a.x - b.x).normalized()
        lines.append(Vector3(normal.x, normal.y, -normal.dot(Vector2(a.x, a.z))))
    var on_line: Array = []  # line index -> positions on it
    on_line.resize(lines.size())
    var lines_of: Dictionary = {}  # position -> PackedInt32Array of line indices
    for position: Vector3 in vertices:
        var mine := PackedInt32Array()
        for line in lines.size():
            if absf(_distance(position, lines[line])) < 1.0e-6:
                mine.append(line)
                if on_line[line] == null:
                    on_line[line] = []
                on_line[line].append(position)
        lines_of[position] = mine
    for piece: Array in pieces:
        var ring: Array = []
        for index in piece.size():
            var a: Vector3 = piece[index][0]
            var b: Vector3 = piece[(index + 1) % piece.size()][0]
            ring.append(piece[index])
            var between: Array = []
            var b_lines: PackedInt32Array = lines_of[b]
            for line: int in lines_of[a]:
                if not b_lines.has(line):
                    continue
                for position: Vector3 in on_line[line]:
                    var t := _along(a, b, position)
                    if t > 0.0:
                        between.append([t, vertices[position]])
            between.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
            for pair: Array in between:
                if (ring.back()[0] as Vector3).distance_squared_to(pair[1][0]) > 1.0e-12:
                    ring.append(pair[1])
        var moved := false
        for vertex: Array in ring:
            if shift.has(vertex[0]):
                moved = true
                break
        if not moved:
            _fan(piece, result)
            continue
        var centre: Array = (ring[0] as Array).duplicate()
        for index in range(1, ring.size()):
            for slot in centre.size():
                centre[slot] += ring[index][slot]
        for slot in centre.size():
            centre[slot] /= float(ring.size())
        var flat_centre: Vector3 = centre[0]
        centre[0] = flat_centre + _fade_shift(flat_centre, snap)
        for index in ring.size():
            var a: Array = ring[index]
            var b: Array = ring[(index + 1) % ring.size()]
            if (a[0] - flat_centre).cross(b[0] - flat_centre).length_squared() < 1.0e-16:
                continue
            result.append([centre, _shifted(a, shift), _shifted(b, shift)])
    return result


static func _shifted(vertex: Array, shift: Dictionary) -> Array:
    if not shift.has(vertex[0]):
        return vertex
    var moved := vertex.duplicate()
    moved[0] = vertex[0] + shift[vertex[0]]
    return moved


## A convex piece fanned from its first vertex, slivers dropped.
static func _fan(piece: Array, result: Array) -> void:
    for corner in range(1, piece.size() - 1):
        var a: Vector3 = piece[0][0]
        var b: Vector3 = piece[corner][0]
        var c: Vector3 = piece[corner + 1][0]
        if (b - a).cross(c - a).length_squared() >= 1.0e-16:
            result.append([piece[0], piece[corner], piece[corner + 1]])


## [param faces] (around [param origin]) minus every opening of [param placements]. With [param data] and the
## chunk's cell size [param cell_m], the cut edge lands on the relief (see [method _snap]).
static func collision_faces(faces: PackedVector3Array, origin: Vector3, placements: Array[CavePlacement],
        data: PlanetData = null, cell_m: float = INF) -> PackedVector3Array:
    if data != null and not placements.is_empty():
        return CaveGround.run(data, func(): return _collision_faces(faces, origin, placements, data, cell_m))
    return _collision_faces(faces, origin, placements, null, INF)


static func _collision_faces(faces: PackedVector3Array, origin: Vector3, placements: Array[CavePlacement],
        data: PlanetData, cell_m: float) -> PackedVector3Array:
    var result := faces
    if faces.is_empty() or placements.is_empty():
        return faces
    # Clipping can only shrink this box. Compute it once, not once per planetary cave.
    var world_bounds := AABB(faces[0] + origin, Vector3.ZERO)
    for point in faces:
        world_bounds = world_bounds.expand(point + origin)
    var openings: Array[Dictionary] = []
    var bored: Array = []  # per opening: the bored porches of its cave (see _snap)
    for placement in placements:
        var own := placement.openings()
        var porches := own.filter(func(other: Dictionary) -> bool: return other.has("axis"))
        for opening in own:
            openings.append(opening)
            bored.append(porches)
    for opening_index in openings.size():
        var opening := openings[opening_index]
        var frame: Transform3D = opening.frame
        var inverse := frame.affine_inverse()
        if result.is_empty():
            break
        var axis := _axis(opening)
        var cut_bounds := AABB(Vector3(-float(opening.width) * 0.5, axis.x, -float(opening.length)),
            Vector3(float(opening.width), axis.y - axis.x, float(opening.length) + float(opening.get("back", 0.0))))
        if not (inverse * world_bounds).intersects(cut_bounds):
            continue
        var snap := _snap(opening, data, cell_m, bored[opening_index])
        var out := PackedVector3Array()
        for index in range(0, result.size(), 3):
            var poly: Array = []
            for corner in 3:
                poly.append([inverse * (result[index + corner] + origin)])
            if not _overlaps(poly, float(opening.width) * 0.5, float(opening.length), float(opening.get("back", 0.0)), axis):
                for corner in 3:
                    out.append(result[index + corner])
                continue
            var pieces := _pieces(poly, float(opening.width) * 0.5, float(opening.length),
                opening.get("polygon", PackedVector2Array()), axis, opening.has("axis"), opening.get("parts", []))
            for triangle: Array in _triangles(poly, pieces, snap):
                for vertex: Array in triangle:
                    out.append(frame * (vertex[0] as Vector3) - origin)
        result = out
    return result


## [param faces] minus one opening's prism, in the faces' own coordinates; [param to_frame] maps them into the
## opening's frame. A version 9 porch opens its mouth this way in its approach's cliff.
static func subtract(faces: PackedVector3Array, to_frame: Transform3D, opening: Dictionary) -> PackedVector3Array:
    var back := to_frame.affine_inverse()
    var axis := _axis(opening)
    var half := float(opening.width) * 0.5
    var out := PackedVector3Array()
    for index in range(0, faces.size(), 3):
        var poly: Array = []
        for corner in 3:
            poly.append([to_frame * faces[index + corner]])
        if not _overlaps(poly, half, float(opening.length), float(opening.get("back", 0.0)), axis):
            out.append_array(faces.slice(index, index + 3))
            continue
        for piece: Array in _pieces(poly, half, float(opening.length), opening.get("polygon", PackedVector2Array()),
                axis, opening.has("axis"), opening.get("parts", [])):
            for corner in range(1, piece.size() - 1):
                var a: Vector3 = piece[0][0]
                var b: Vector3 = piece[corner][0]
                var c: Vector3 = piece[corner + 1][0]
                if (b - a).cross(c - a).length_squared() >= 1.0e-16:
                    out.append_array(PackedVector3Array([back * a, back * b, back * c]))
    return out


## [param source] (around [param origin]) minus every opening of [param placements], attributes interpolated.
## With [param data] and the chunk's cell size [param cell_m], the cut edge lands on the relief (see [method _snap]).
static func mesh(source: ArrayMesh, origin: Vector3, placements: Array[CavePlacement], data: PlanetData = null,
        cell_m: float = INF) -> ArrayMesh:
    if placements.is_empty():
        return source
    if data != null:
        return CaveGround.run(data, func(): return _mesh(source, origin, placements, data, cell_m))
    return _mesh(source, origin, placements, null, INF)


static func _mesh(source: ArrayMesh, origin: Vector3, placements: Array[CavePlacement], data: PlanetData,
        cell_m: float) -> ArrayMesh:
    var result := source
    var openings: Array[Dictionary] = []
    var bored: Array = []  # per opening: the bored porches of its cave (see _snap)
    for placement in placements:
        var own := placement.openings()
        var porches := own.filter(func(other: Dictionary) -> bool: return other.has("axis"))
        for opening in own:
            openings.append(opening)
            bored.append(porches)
    for opening_index in openings.size():
        var opening := openings[opening_index]
        var frame: Transform3D = opening.frame
        var inverse := frame.affine_inverse()
        var axis := _axis(opening)
        var cut_bounds := AABB(Vector3(-float(opening.width) * 0.5, axis.x, -float(opening.length)),
            Vector3(float(opening.width), axis.y - axis.x, float(opening.length) + float(opening.get("back", 0.0))))
        if not (inverse * (Transform3D(Basis.IDENTITY, origin) * result.get_aabb())).intersects(cut_bounds):
            continue
        var snap := _snap(opening, data, cell_m, bored[opening_index])
        var output := ArrayMesh.new()
        var surface_map: Dictionary = {}
        for surface_index in result.get_surface_count():
            var arrays := result.surface_get_arrays(surface_index)
            var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
            var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
            if indices.is_empty():
                for index in positions.size():
                    indices.append(index)
            var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
            var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
            var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array()
            var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
            # Native chunks encode skirt offsets as CUSTOM0 RGB_FLOAT. Preserve
            # those offsets as well as UV2; both are read by terrain shaders.
            var custom: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0] if arrays[Mesh.ARRAY_CUSTOM0] != null else PackedFloat32Array()
            var rocks: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1] if arrays[Mesh.ARRAY_CUSTOM1] != null else PackedFloat32Array()
            var out_rocks := PackedFloat32Array()
            var out_pos := PackedVector3Array()
            var out_norm := PackedVector3Array()
            var out_uv := PackedVector2Array()
            var out_uv2 := PackedVector2Array()
            var out_col := PackedColorArray()
            var out_custom := PackedFloat32Array()
            for index in range(0, indices.size(), 3):
                var poly: Array = []
                for corner in 3:
                    var vi := indices[index + corner]
                    poly.append([inverse * (positions[vi] + origin),
                        normals[vi] if not normals.is_empty() else Vector3.UP,
                        uvs[vi] if not uvs.is_empty() else Vector2.ZERO,
                        colors[vi] if not colors.is_empty() else Color.WHITE,
                        uv2s[vi] if not uv2s.is_empty() else Vector2.ZERO,
                        Vector3(custom[vi * 3], custom[vi * 3 + 1], custom[vi * 3 + 2]) if not custom.is_empty() else Vector3.ZERO,
                        Color(rocks[vi * 4], rocks[vi * 4 + 1], rocks[vi * 4 + 2], rocks[vi * 4 + 3]) \
                            if not rocks.is_empty() else Color(0, 0, 0, 0)])
                var cut := _overlaps(poly, float(opening.width) * 0.5, float(opening.length),
                    float(opening.get("back", 0.0)), axis)
                var pieces: Array = _pieces(poly, float(opening.width) * 0.5, float(opening.length),
                    opening.get("polygon", PackedVector2Array()), axis, opening.has("axis"), opening.get("parts", [])) \
                    if cut else [poly]
                for triangle: Array in _triangles(poly, pieces, snap if cut else {}):
                    for vertex: Array in triangle:
                        out_pos.append(frame * vertex[0] - origin)
                        out_norm.append((vertex[1] as Vector3).normalized())
                        out_uv.append(vertex[2])
                        out_col.append(vertex[3])
                        out_uv2.append(vertex[4])
                        var offset: Vector3 = vertex[5]
                        out_custom.append_array(PackedFloat32Array([offset.x, offset.y, offset.z]))
                        var rock: Color = vertex[6]
                        out_rocks.append_array(PackedFloat32Array([rock.r, rock.g, rock.b, rock.a]))
            if out_pos.is_empty():
                continue
            var output_arrays: Array = []
            output_arrays.resize(Mesh.ARRAY_MAX)
            output_arrays[Mesh.ARRAY_VERTEX] = out_pos
            output_arrays[Mesh.ARRAY_NORMAL] = out_norm
            if not uvs.is_empty():
                output_arrays[Mesh.ARRAY_TEX_UV] = out_uv
            if not colors.is_empty():
                output_arrays[Mesh.ARRAY_COLOR] = out_col
            if not uv2s.is_empty():
                output_arrays[Mesh.ARRAY_TEX_UV2] = out_uv2
            var flags := 0
            if not custom.is_empty():
                output_arrays[Mesh.ARRAY_CUSTOM0] = out_custom
                flags = Mesh.ARRAY_CUSTOM_RGB_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
            if not rocks.is_empty():
                output_arrays[Mesh.ARRAY_CUSTOM1] = out_rocks
                flags |= Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT
            if arrays[Mesh.ARRAY_TANGENT] != null:
                var out_indices := PackedInt32Array()
                for index in out_pos.size():
                    out_indices.append(index)
                # Use the native tangent implementation, which keeps CUSTOM0.
                output_arrays[Mesh.ARRAY_TANGENT] = PlanetChunk._compute_tangents(out_pos, out_norm, out_uv, out_indices)
            surface_map[surface_index] = output.get_surface_count()
            output.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, output_arrays, [], {}, flags)
            output.surface_set_material(output.get_surface_count() - 1, result.surface_get_material(surface_index))
        for key in result.get_meta_list():
            output.set_meta(key, result.get_meta(key))
        # The prebuilt road mesh still spans the old, uncut terrain. Let the
        # native road splitter rebuild it from the clipped surfaces instead.
        if output.has_meta("roads_mesh"):
            output.remove_meta("roads_mesh")
        if output.has_meta("road_surfaces"):
            var roads := PackedInt32Array()
            for old_index in output.get_meta("road_surfaces"):
                if surface_map.has(old_index):
                    roads.append(surface_map[old_index])
            output.set_meta("road_surfaces", roads)
        result = output
    return result
