extends GutTest
## A village mine's working face (MineFace, MineSite): the seeded fault, the hit test, a layer falling (the
## gallery moves on, never past its limit), and the gold its rocks carry.

var _mine: MineSite


func before_each() -> void:
    _mine = MineSite.new()
    _mine.seed = 4242
    _mine._layout = MineLayout.generate(_mine.seed, _mine.layout_settings(), MineLayout.STYLE_STRAIGHT)
    var limits := {}
    for gallery: Dictionary in _mine._layout.galleries:
        limits[str(gallery.id)] = float(gallery.initial_m) + 4.0
    _mine.gallery_max_m = limits
    _mine._dug = MineLayout.dug(_mine._layout, _mine.faces, _mine.gallery_max_m)


func after_each() -> void:
    _mine.free()


func _face(id: int) -> MineFace:
    var face := MineFace.new()
    var fault := _mine.fault_of(id, int(_mine.face_step.get(str(id), 0)))
    face.mine = _mine
    face.gallery = id
    face.fault_normal = fault[0]
    face.fault_offset = fault[1]
    face.tolerance_m = _mine.fault_tolerance_m
    face.transform = _mine.face_frame(id, float(_mine._dug[id]))
    return autofree(face)


func test_faults_are_seeded_and_cross_the_face() -> void:
    var seen := {}
    for step in 12:
        var fault := _mine.fault_of(0, step)
        assert_eq(str(fault), str(_mine.fault_of(0, step)), "same layer, same fault")
        assert_almost_eq((fault[0] as Vector2).length(), 1.0, 1.0e-6)
        var center := Vector2(0.0, _mine.gallery_height_m * 0.45)
        assert_lte(absf(center.dot(fault[0]) - float(fault[1])), 0.6 + 1.0e-6, "passes near the face's middle")
        seen[str(fault)] = true
    assert_gt(seen.size(), 8, "a new fault at each layer")


func test_face_frame_looks_down_the_gallery() -> void:
    var gallery: Dictionary = _mine._layout.galleries[0]
    var dug := float(_mine._dug[0])
    var frame := _mine.face_frame(0, dug)
    assert_true(frame.basis.is_equal_approx(frame.basis.orthonormalized()), "orthonormal")
    assert_almost_eq(frame.basis.y, Vector3.UP, Vector3.ONE * 1.0e-6)
    var along := MineLayout.direction_at(gallery, dug)
    assert_gt((-frame.basis.z).dot(Vector3(along.x, 0, along.z).normalized()), 0.999, "-Z runs along the gallery")
    assert_almost_eq(frame.origin, MineLayout.point_at(gallery, dug), Vector3.ONE * 1.0e-6)


func test_hit_on_the_fault_whatever_the_depth() -> void:
    var face := _face(0)
    var normal: Vector2 = face.fault_normal
    var on_line := normal * face.fault_offset + Vector2(-normal.y, normal.x) * 0.7
    for depth: float in [0.0, -1.0, -2.8]:
        assert_true(face.is_on_fault_local(Vector3(on_line.x, on_line.y, depth)), "on the fault at %.1f m" % depth)
        var off := on_line + normal * 0.5
        assert_false(face.is_on_fault_local(Vector3(off.x, off.y, depth)), "half a metre off")


func test_the_tool_reads_the_face() -> void:
    var face := _face(0)
    assert_eq(face.perforation_duration(), 20.0, "held 20 s")
    var request := face.perforate_request(face.transform.origin)
    assert_eq(request.action, "perforate_mine_face")
    assert_eq(int(request.gallery), 0)
    assert_eq(int(request.step), 0)
    assert_true(MiningTool.is_target(face), "the mining tool aims at it")
    assert_eq(face._shell().size(), 6 * 12 * 6, "a shell of the face's rock")


func test_a_layer_falls_and_the_gallery_moves_on() -> void:
    var gallery: Dictionary = _mine._layout.galleries[0]
    var initial := float(gallery.initial_m)
    _mine.server_break_face(0)
    assert_almost_eq(float(_mine.faces["0"]), 1.5, 1.0e-6, "moved on by a layer")
    assert_eq(int(_mine.face_step["0"]), 1, "next layer")
    _mine._dug = MineLayout.dug(_mine._layout, _mine.faces, _mine.gallery_max_m)
    _mine.server_break_face(0)
    _mine._dug = MineLayout.dug(_mine._layout, _mine.faces, _mine.gallery_max_m)
    _mine.server_break_face(0)
    _mine._dug = MineLayout.dug(_mine._layout, _mine.faces, _mine.gallery_max_m)
    assert_almost_eq(float(_mine._dug[0]), initial + 4.0, 1.0e-6, "never past its limit")
    assert_false(MineLayout.face_open(_mine._layout, 0, _mine.faces, _mine.gallery_max_m), "the face is closed")
    var steps := int(_mine.face_step["0"])
    _mine.server_break_face(0)
    assert_eq(int(_mine.face_step["0"]), steps, "a closed face drops nothing")


func test_a_stale_layer_or_a_miss_drops_nothing() -> void:
    var face := _face(0)
    face.step = 0
    _mine._faces[0] = face
    var normal: Vector2 = face.fault_normal
    var miss := normal * (face.fault_offset + 0.8)
    var hit_miss := face.transform * Vector3(miss.x, miss.y, -1.0)
    assert_false(_mine.server_perforate_face(null, 0, 0, hit_miss), "off the fault")
    var on := normal * face.fault_offset
    var hit_on := face.transform * Vector3(on.x, on.y, -1.0)
    assert_false(_mine.server_perforate_face(null, 0, 3, hit_on), "another layer")
    assert_true(_mine.server_perforate_face(null, 0, 0, hit_on), "on the fault, this layer")
    assert_eq(int(_mine.face_step["0"]), 1)
    _mine._faces.erase(0)


func test_gold_purity_close_to_the_layer_draw() -> void:
    for target: float in [0.02, 0.1, 0.17, 0.3]:
        for index in 6:
            var ore_seed := MineSite.gold_seed("mine|layer|3|7", index, target)
            var richness := float(absi(ore_seed.hash()) % 1000) / 1000.0
            assert_almost_eq(richness, target, 0.0101, "rock %d near %.2f" % [index, target])


func test_debris_sizes_up_to_two_metres() -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = 5
    var sizes := {}
    for draw in 400:
        var pick: Array = MineSite._pick_debris(rng)
        assert_lte(float(pick[1]), 2.0)
        assert_true(ResourceLoader.exists("res://" + MineSite.DEBRIS_DIR + str(pick[0])), str(pick[0]))
        sizes[pick[1]] = true
    assert_eq(sizes.size(), MineSite.DEBRIS.size(), "every size drops")
