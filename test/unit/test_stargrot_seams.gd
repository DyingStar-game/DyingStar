extends GutTest


func test_join_keeps_every_edge_including_vertical_sides_and_uneven_floor() -> void:
    var arch := PackedVector3Array([Vector3(4, 0, 0), Vector3(4, 3, 0), Vector3(1, 5, 0),
        Vector3(-3, 4, 0), Vector3(-4, 0, 0)])
    var loop := PackedVector3Array([Vector3(3, 0, 2), Vector3(3, 2, 2), Vector3(2.5, 4, 2),
        Vector3(0, 4.5, 2), Vector3(-2.5, 3, 2), Vector3(-3, 0.2, 2), Vector3(0, -0.3, 2)])
    var mesh := {"wall": CaveGenerator._empty_surface(), "floor": CaveGenerator._empty_surface()}
    CaveMeshAssembly.join(mesh, arch, loop, Vector3(INF, INF, INF))
    var edges := {}
    for surface: Dictionary in [mesh.wall, mesh.floor]:
        var vertices: PackedVector3Array = surface.vertices
        for index in range(0, vertices.size(), 3):
            for side in 3:
                var key := _edge(vertices[index + side], vertices[index + (side + 1) % 3])
                edges[key] = int(edges.get(key, 0)) + 1
    for boundary: PackedVector3Array in [arch, loop]:
        for index in boundary.size():
            var key := _edge(boundary[index], boundary[(index + 1) % boundary.size()])
            assert_eq(int(edges.get(key, 0)), 1, "original boundary edge retained exactly once")
            edges.erase(key)
    for count: int in edges.values():
        assert_eq(count, 2, "interior edge shared by two triangles, no crack or duplicate")


func _edge(a: Vector3, b: Vector3) -> String:
    var keys := [str(a), str(b)]
    keys.sort()
    return keys[0] + ":" + keys[1]


func test_cliff_intersection_vertices_replace_analytic_rim() -> void:
    var arch := PackedVector2Array([Vector2(4, 0), Vector2(0, 4), Vector2(-4, 0)])
    var rims: Array[float] = [1.0, 1.0, 1.0]
    var wall := {"vertices": PackedVector3Array([Vector3(4, 0, 1.2), Vector3(2, 2, 1.8), Vector3(0, 4, 1.4)])}
    var floor_surface := {"vertices": PackedVector3Array()}
    var seam := CavePorchSeam.refine({"wall": wall, "floor": floor_surface}, arch, rims, arch,
        {"up": Vector3.UP, "forward": Vector3.BACK})
    var index: int = seam.arch.find(Vector2(2, 2))
    assert_gte(index, 0, "keeps a cliff triangle intersection between two arch samples")
    if index >= 0:
        assert_almost_eq(float(seam.rims[index]), 1.8, 0.000001, "uses displayed cliff depth")
        assert_eq(seam.section[index], Vector2(2, 2), "rear seam stays on the original ring edge")


func test_entry_has_relief_even_before_first_room() -> void:
    var profile := preload("res://test/unit/stargrot_fixture.gd").profile(0)
    var graph := CaveNetwork.layout(profile.snapshot(73))
    var found := false
    for volume: Dictionary in graph.volumes:
        if volume.kind == "tunnel" and volume.a.z < float(graph.entry_end):
            found = true
            assert_gt(float(volume.amp), 0.0)
            assert_gt(float(volume.erode_a), 0.0)
    assert_true(found)


func test_texture_frame_does_not_move_geometry_or_collision() -> void:
    var wall := CaveGenerator._empty_surface()
    CaveGenerator._triangle(wall, Vector3.ZERO, Vector3.RIGHT, Vector3.UP, Vector3.BACK)
    var data := {"spec": {}, "wall": wall, "floor": CaveGenerator._empty_surface(), "faces": wall.vertices}
    var offset := Vector3(2, -30, 12)
    var root := CavePreviewBuilder.instantiate(data, null, true, true, offset)
    add_child_autofree(root)
    var visual: MeshInstance3D = root.get_node("CaveSurface")
    var vertices: PackedVector3Array = visual.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
    var collider: CollisionShape3D = root.get_node("CaveCollision").get_child(0)
    var faces: PackedVector3Array = collider.shape.get_faces()
    for index in vertices.size():
        assert_eq(vertices[index], wall.vertices[index] + offset, "texture uses site coordinates")
        assert_eq(visual.transform * vertices[index], faces[index], "visual and physical positions agree")
