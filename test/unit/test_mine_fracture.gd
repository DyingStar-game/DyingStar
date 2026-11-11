extends GutTest
## A mine face's layer broken into blocks (MineFracture, CaveNetworkMesher.BuildFragments): seeded sites on both
## sides of the fault, cracks running out from the drill, blocks that fill the layer, stay on their side of the
## fault and never overlap their neighbours.

var _mine: MineSite


func before_each() -> void:
    _mine = MineSite.new()
    _mine.seed = 4242
    _mine._layout = MineLayout.generate(_mine.seed, _mine.layout_settings(), MineLayout.STYLE_STRAIGHT)
    var limits := {}
    for gallery: Dictionary in _mine._layout.galleries:
        limits[str(gallery.id)] = float(gallery.initial_m) + 20.0
    _mine.gallery_max_m = limits
    _mine._dug = MineLayout.dug(_mine._layout, _mine.faces, _mine.gallery_max_m)


func after_each() -> void:
    _mine.free()


func _seeds(step: int) -> Dictionary:
    var fault := _mine.fault_of(0, step)
    return MineFracture.seeds(_mine.seed, 0, step, 3.0, 4.5, 0.8, fault[0], fault[1], 20, 30)


func test_sites_are_seeded_and_on_both_sides_of_the_fault() -> void:
    var first := _seeds(0)
    assert_eq(str(first), str(_seeds(0)), "same layer, same sites")
    assert_ne(str(first.points), str(_seeds(1).points), "another layer, other sites")
    var count := (first.points as PackedVector3Array).size()
    assert_between(count, 20, 34, "20 to 30 sites, a couple more to fill a side")
    var per_side := [0, 0]
    for side: int in first.sides:
        per_side[side] += 1
    assert_gte(per_side[0], 2)
    assert_gte(per_side[1], 2)
    for point: Vector3 in first.points:
        assert_lte(point.x * point.x / 9.0 + point.y * point.y / 20.25, 0.96 + 1.0e-6, "on the face, off its rim")
        assert_lt(point.z, 0.0, "in the rock, behind the face")


func test_cracks_run_out_from_the_drill() -> void:
    var points := PackedVector3Array([Vector3(0, 2, -3), Vector3(1, 2, -3), Vector3(2.5, 1, -2), Vector3(-2.5, 4, -1)])
    var onsets := MineFracture.onsets(points, Vector3(0, 2, -3))
    assert_almost_eq(onsets[0], MineFracture.ONSET_FIRST, 1.0e-6, "the drilled block first")
    assert_lt(onsets[1], onsets[2])
    assert_almost_eq(onsets[3], MineFracture.ONSET_FIRST + MineFracture.ONSET_SPAN, 1.0e-5, "the farthest last")


func test_blocks_fill_the_layer_and_keep_to_their_cells() -> void:
    if not MineMesher.warm():
        pending("native mesher missing")
        return
    var from := float(_mine._dug[0])
    var to := from + _mine.layer_m
    var plan := MineFracture.plan(_mine, 0, 0, from, to, MineFracture.BODY_GAP_M)
    assert_false(plan.is_empty())
    var started := Time.get_ticks_usec()
    var blocks := MineFracture.build(plan)
    var spent := (Time.get_ticks_usec() - started) / 1000.0
    var shut := MineFracture.build(MineFracture.plan(_mine, 0, 0, from, to, 0.0))
    assert_eq(blocks.size(), (plan.points as PackedVector3Array).size(), "one block per site")
    var volume := 0.0
    var shut_volume := 0.0
    var largest := 0.0
    var triangles := 0
    var rocks := 0
    var inverse := (plan.frame as Transform3D).affine_inverse()
    var points: PackedVector3Array = plan.points
    var sides: PackedInt32Array = plan.sides
    var normal: Vector2 = plan.fault_normal
    var offset := float(plan.fault_offset)
    var worst_fault := 0.0
    var worst_cell := -1.0
    for block: Dictionary in blocks:
        volume += float(block.volume)
        largest = maxf(largest, float(block.size))
        triangles += ((block.wall as PackedInt32Array).size() + (block.crack as PackedInt32Array).size()) / 3
        rocks += 1 if float(block.volume) >= MineFracture.DUST_M3 else 0
        var i := int(block.index)
        var sign := 1.0 if sides[i] == 1 else -1.0
        for vertex: Vector3 in block.vertices:
            var local := inverse * vertex
            worst_fault = minf(worst_fault, sign * (Vector2(local.x, local.y).dot(normal) - offset))
            for j in points.size():
                if j == i or sides[j] != sides[i]:
                    continue
                var between := points[i].distance_to(points[j])
                var past := (local.distance_squared_to(points[i]) - local.distance_squared_to(points[j])) / (2.0 * between)
                worst_cell = maxf(worst_cell, past)
    for block: Dictionary in shut:
        shut_volume += float(block.volume)
    gut.p("layer of %.2f m: %d blocks (%d rocks), %.2f m³, largest %.2f m, %d triangles, %.1f ms"
            % [to - from, blocks.size(), rocks, volume, largest, triangles, spent])
    # The face's half-ellipse (about 21 m²) over a layer of 0.8 m, give or take the wall's relief.
    assert_between(shut_volume, 8.0, 30.0, "the blocks fill the layer")
    assert_almost_eq(volume, shut_volume, shut_volume * 0.1, "the gaps take little rock")
    assert_gt(rocks, 10, "most blocks become rocks")
    # 20 to 30 blocks over the face: about 1.2 m across on average, the longest Voronoi cells near twice that.
    assert_lte(largest, 2.5, "no block much over 2 m")
    assert_gte(worst_fault, -0.02, "no block crosses the fault")
    assert_lte(worst_cell, -MineFracture.BODY_GAP_M * 0.5 + 0.05, "no block reaches into its neighbour's cell")


func test_blocks_of_a_layer_are_the_same_every_time() -> void:
    if not MineMesher.warm():
        pending("native mesher missing")
        return
    var from := float(_mine._dug[0])
    var plan := MineFracture.plan(_mine, 0, 3, from, from + _mine.layer_m, 0.0)
    var first := MineFracture.build(plan)
    var again := MineFracture.build(MineFracture.plan(_mine, 0, 3, from, from + _mine.layer_m, 0.0))
    assert_eq(first.size(), again.size())
    for index in first.size():
        assert_eq(first[index].centroid, again[index].centroid, "block %d" % index)
        assert_eq(first[index].vertices, again[index].vertices, "block %d" % index)
    var hull := MineFracture.hull_points(first[0])
    assert_gt(hull.size(), 3, "a hull to collide with")


func test_a_block_is_a_closed_surface() -> void:
    if not MineMesher.warm():
        pending("native mesher missing")
        return
    var from := float(_mine._dug[0])
    var blocks := MineFracture.build(MineFracture.plan(_mine, 0, 0, from, from + _mine.layer_m, MineFracture.BODY_GAP_M))
    for block: Dictionary in blocks:
        if float(block.volume) <= 0.0:
            continue
        # Every edge shared by exactly two triangles, once each way: what CSG needs to carve it.
        var edges := {}
        var indices: PackedInt32Array = (block.wall as PackedInt32Array).duplicate()
        indices.append_array(block.crack)
        for k in range(0, indices.size(), 3):
            for e in 3:
                var a := indices[k + e]
                var b := indices[k + (e + 1) % 3]
                var directed := "%d>%d" % [a, b]
                edges[directed] = int(edges.get(directed, 0)) + 1
        var open := 0
        for directed: String in edges:
            var ends := directed.split(">")
            if int(edges[directed]) != 1 or int(edges.get("%s>%s" % [ends[1], ends[0]], 0)) != 1:
                open += 1
        assert_eq(open, 0, "block %d watertight and consistently wound" % int(block.index))


func test_a_rock_rebuilds_its_block_without_the_mine() -> void:
    if not MineMesher.warm():
        pending("native mesher missing")
        return
    var from := float(_mine._dug[0])
    var ref := MineFracture.layer_ref(_mine, 0, 2, from, from + _mine.layer_m)
    assert_eq(ref.style, MineLayout.STYLE_STRAIGHT)
    assert_true((ref.near as Dictionary).has(0), "its own gallery")
    var here := MineFracture.build(MineFracture.plan_from(_mine.layout(), ref, 0.0))
    # Far from the mine: only the ref, the plan generated again from the seed.
    var portable: Dictionary = JSON.parse_string(JSON.stringify(ref))
    MineFracture._layouts.clear()
    var blocks: Variant = MineFracture.blocks_for(portable, 0.0)
    await wait_until(func() -> bool: return MineFracture.blocks_for(portable, 0.0) != null, 20.0)
    blocks = MineFracture.blocks_for(portable, 0.0)
    assert_eq((blocks as Array).size(), here.size(), "the same blocks")
    for index in here.size():
        assert_true((blocks[index].centroid as Vector3).is_equal_approx(here[index].centroid), "block %d" % index)

    var rock: MineRock = load("res://" + MineRock.SCENE).instantiate()
    var block_ref := portable.duplicate(true)
    block_ref.index = 3
    rock.apply_prop_data({"mine_block": block_ref, "mineral_id": "gold"})
    add_child_autofree(rock)
    await wait_until(func() -> bool: return rock._shaped, 5.0)
    assert_true(rock._shaped, "shaped from its block")
    assert_true(rock.is_in_group("miningrock"), "a mining rock: the tool aims at it")
    assert_gt((rock.get_node("CollisionShape3D").shape as ConvexPolygonShape3D).points.size(), 3, "its hull")
    assert_almost_eq(rock.longest_side(), float(blocks[3].size), 0.3, "measured on its block")
    assert_eq(rock._split_data().mine_block, block_ref, "its halves are the same block")
    # Cut in two through its middle, as a perforation does: CSG carves the block (a closed surface).
    await wait_frames(2)
    var whole: AABB = rock._piece_aabb()
    rock.fractures = [{"fractured": true, "rotation_x": 0.0, "rotation_y": 0.0, "rotation_z": 0.0,
        "plane_offset": whole.get_center().x, "keep_side": 1,
        "cut_position": {"x": rock.position.x, "y": rock.position.y, "z": rock.position.z},
        "cut_rotation": {"x": rock.rotation.x, "y": rock.rotation.y, "z": rock.rotation.z}}]
    await rock._apply_cuts()
    await wait_frames(2)
    var half: AABB = rock._piece_aabb()
    gut.p("block %.2f m across x, cut: %.2f m" % [whole.size.x, half.size.x])
    assert_lt(half.size.x, whole.size.x * 0.7, "the cut took half of it")
    assert_gt(half.size.x, 0.05, "and left the other half")


func test_a_drilled_face_cracks_then_shuts_or_falls() -> void:
    if not MineMesher.warm():
        pending("native mesher missing")
        return
    if GameOrchestrator.is_server():
        pending("the cracking face is drawn by clients")
        return
    var mine := MineSite.new()
    mine.seed = _mine.seed
    mine.style = MineLayout.STYLE_STRAIGHT
    mine.gallery_max_m = _mine.gallery_max_m
    add_child_autofree(mine)
    await wait_until(func() -> bool: return mine._faces.has(0), 5.0)
    var face: MineFace = mine._faces[0]
    var hit := face.global_transform * Vector3(0.0, 2.0, -2.0)

    # Let go halfway: the nearest blocks came out of the wall, the farthest not yet; then the wall shuts.
    face.fracture_begin(hit)
    assert_true(mine._previews.has(0), "the layer shows")
    await wait_until(func() -> bool: return mine._previews.has(0) and bool(mine._previews[0].shown), 20.0)
    assert_true(bool(mine._previews[0].shown), "its blocks show once the rock behind them is open")
    face.fracture_progress(0.5)
    await wait_frames(2)
    var moved := 0
    var blocks: Node3D = mine._previews[0].node
    for block: Node3D in blocks.get_children():
        moved += 1 if not block.transform.is_equal_approx(Transform3D.IDENTITY) else 0
    assert_between(moved, 1, blocks.get_child_count() - 1, "cracks halfway across the face")
    face.fracture_end(false)
    assert_eq(str(mine._previews[0].state), "closing")
    await wait_until(func() -> bool: return not mine._previews.has(0), 20.0)
    assert_false(mine._previews.has(0), "the wall shut again")
    assert_almost_eq(float(mine._cells_dug[0]), float(mine._dug[0]), 1.0e-6, "the rock is whole again")

    # Held to the end: the layer falls, each block goes as its rock arrives.
    face.fracture_begin(hit)
    await wait_until(func() -> bool: return mine._previews.has(0) and bool(mine._previews[0].shown), 20.0)
    face.fracture_progress(1.0)
    face.fracture_end(true)
    assert_eq(str(mine._previews[0].state), "done", "drilled, waiting for the server")
    mine.apply_prop_data({"faces": {"0": mine.layer_m}, "face_step": {"0": 1}})
    assert_eq(str(mine._previews[0].state), "falling")
    var preview: Dictionary = mine._previews[0]
    for block: Dictionary in preview.blocks:
        mine.rock_arrived(0, 0, int(block.index))
    var shown := 0
    for block: Node3D in (preview.node as Node3D).get_children():
        shown += 1 if block.visible else 0
    assert_eq(shown, 0, "every block handed over to its rock")
    await wait_until(func() -> bool: return not mine._previews.has(0), MineSite.FRACTURE_WAIT_S + 2.0)
    assert_false(mine._previews.has(0), "the layer is gone")
