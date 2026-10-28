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
    for plane in planes:
        if remainder.size() < 3:
            break
        var outside := _clip(remainder, plane, false)
        if outside.size() >= 3:
            kept.append(outside)
        remainder = _clip(remainder, plane, true)
    return kept


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


static func collision_faces(faces: PackedVector3Array, origin: Vector3, placements: Array[CavePlacement]) -> PackedVector3Array:
    var result := faces
    if faces.is_empty() or placements.is_empty():
        return faces
    # Clipping can only shrink this box. Compute it once, not once per planetary cave.
    var world_bounds := AABB(faces[0] + origin, Vector3.ZERO)
    for point in faces:
        world_bounds = world_bounds.expand(point + origin)
    var openings: Array[Dictionary] = []
    for placement in placements:
        openings.append_array(placement.openings())
    for opening: Dictionary in openings:
        var frame: Transform3D = opening.frame
        var inverse := frame.affine_inverse()
        if result.is_empty():
            break
        var axis := _axis(opening)
        var cut_bounds := AABB(Vector3(-float(opening.width) * 0.5, axis.x, -float(opening.length)),
            Vector3(float(opening.width), axis.y - axis.x, float(opening.length) + float(opening.get("back", 0.0))))
        if not (inverse * world_bounds).intersects(cut_bounds):
            continue
        var out := PackedVector3Array()
        for index in range(0, result.size(), 3):
            var poly: Array = []
            for corner in 3:
                poly.append([inverse * (result[index + corner] + origin)])
            if not _overlaps(poly, float(opening.width) * 0.5, float(opening.length), float(opening.get("back", 0.0)), axis):
                for corner in 3:
                    out.append(result[index + corner])
                continue
            for piece: Array in _pieces(poly, float(opening.width) * 0.5, float(opening.length),
                    opening.get("polygon", PackedVector2Array()), axis, opening.has("axis"), opening.get("parts", [])):
                for corner in range(1, piece.size() - 1):
                    var a: Vector3 = piece[0][0]
                    var b: Vector3 = piece[corner][0]
                    var c: Vector3 = piece[corner + 1][0]
                    if (b - a).cross(c - a).length_squared() < 1.0e-16:
                        continue
                    for point in [a, b, c]:
                        out.append(frame * point - origin)
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


static func mesh(source: ArrayMesh, origin: Vector3, placements: Array[CavePlacement]) -> ArrayMesh:
    if placements.is_empty():
        return source
    var result := source
    var openings: Array[Dictionary] = []
    for placement in placements:
        openings.append_array(placement.openings())
    for opening: Dictionary in openings:
        var frame: Transform3D = opening.frame
        var inverse := frame.affine_inverse()
        var axis := _axis(opening)
        var cut_bounds := AABB(Vector3(-float(opening.width) * 0.5, axis.x, -float(opening.length)),
            Vector3(float(opening.width), axis.y - axis.x, float(opening.length) + float(opening.get("back", 0.0))))
        if not (inverse * (Transform3D(Basis.IDENTITY, origin) * result.get_aabb())).intersects(cut_bounds):
            continue
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
                var pieces: Array = _pieces(poly, float(opening.width) * 0.5, float(opening.length),
                    opening.get("polygon", PackedVector2Array()), axis, opening.has("axis"), opening.get("parts", [])) \
                    if _overlaps(poly, float(opening.width) * 0.5, float(opening.length), float(opening.get("back", 0.0)), axis) \
                    else [poly]
                for piece: Array in pieces:
                    for corner in range(1, piece.size() - 1):
                        var a: Vector3 = piece[0][0]
                        var b: Vector3 = piece[corner][0]
                        var c: Vector3 = piece[corner + 1][0]
                        if (b - a).cross(c - a).length_squared() < 1.0e-16:
                            continue
                        for vertex: Array in [piece[0], piece[corner], piece[corner + 1]]:
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
