extends GutTest
## Village mines: the seeded plan (MineLayout), the hole in the ground (MinePlacement) and the rock meshed cell by
## cell (MineMesher / CaveNetworkMesher.BuildRegion).

const SEEDS := [1, 7, 42, 1234, 99991, 314159]


func _deep_cover(_point: Vector3) -> float:
    return 10000.0


func test_same_seed_same_mine() -> void:
    for seed: int in SEEDS:
        var a := MineLayout.generate(seed)
        var b := MineLayout.generate(seed)
        assert_eq(str(a.levels), str(b.levels), "seed %d: same levels" % seed)
        assert_eq(str(a.galleries), str(b.galleries), "seed %d: same galleries" % seed)
        assert_eq(a.style, b.style)


func test_depth_and_levels_follow_the_seed() -> void:
    var depths := {}
    for seed: int in SEEDS:
        var plan := MineLayout.generate(seed)
        var depth := float(plan.depth)
        depths[depth] = true
        assert_between(depth, 250.0, 1000.0, "seed %d: depth" % seed)
        var levels: Array = plan.levels
        assert_eq(float(levels.back().y), -depth, "the bottom of the shaft is a level")
        assert_eq(float(levels[0].y), -40.0, "first level under the ground")
        for index in range(1, levels.size() - 1):
            var gap := float(levels[index - 1].y) - float(levels[index].y)
            assert_between(gap, 60.0, 90.0, "seed %d: spacing" % seed)
        # One level every 60-90 m: the deeper, the more.
        assert_gte(levels.size(), int(floor((depth - 40.0) / 90.0)), "seed %d: enough levels for %d m" % [seed, depth])
        assert_lte(levels.size(), int(ceil((depth - 40.0) / 60.0)) + 2, "seed %d: not too many" % seed)
    assert_gt(depths.size(), 1, "depth varies from mine to mine")


func test_gallery_counts() -> void:
    var plan := MineLayout.generate(42, {}, MineLayout.STYLE_STRAIGHT)
    var per_level := {}
    for gallery: Dictionary in plan.galleries:
        per_level[int(gallery.level)] = int(per_level.get(int(gallery.level), 0)) + 1
    for level: Dictionary in plan.levels:
        assert_between(int(per_level.get(int(level.index), 0)), 2, 6, "galleries of level %d" % level.index)


func test_straight_galleries_keep_their_heading() -> void:
    var plan := MineLayout.generate(7, {}, MineLayout.STYLE_STRAIGHT)
    for gallery: Dictionary in plan.galleries:
        var first := MineLayout.direction_at(gallery, 1.0)
        var last := MineLayout.direction_at(gallery, 480.0)
        assert_almost_eq(first.dot(last), 1.0, 1.0e-6, "gallery %d runs straight" % gallery.id)
        assert_lt(absf(first.y), 0.03, "gentle grade")


func test_chaotic_galleries_wander_and_branch() -> void:
    var turned := 0
    var branches := 0
    for seed: int in SEEDS:
        var plan := MineLayout.generate(seed, {}, MineLayout.STYLE_CHAOTIC)
        for gallery: Dictionary in plan.galleries:
            if int(gallery.parent) >= 0:
                branches += 1
            var start := MineLayout.heading_at(gallery, 1.0)
            for distance in range(20, 480, 20):
                if absf(angle_difference(start, MineLayout.heading_at(gallery, distance))) > deg_to_rad(30.0):
                    turned += 1
                    break
            for distance in range(0, 480, 10):
                var climb := MineLayout.direction_at(gallery, distance + 1.0)
                assert_lt(absf(climb.y), sin(deg_to_rad(35.0)), "walkable grade")
    assert_gt(turned, 10, "chaotic galleries change direction")
    assert_gt(branches, 0, "chaotic galleries branch")


func test_limits_keep_galleries_apart() -> void:
    for seed: int in SEEDS:
        var plan := MineLayout.generate(seed)
        var limits := MineLayout.limits(plan, _deep_cover)
        assert_eq(limits.size(), plan.galleries.size(), "seed %d: every gallery measured" % seed)
        var reach := {}
        for gallery: Dictionary in plan.galleries:
            var limit := float(limits[str(gallery.id)])
            assert_between(limit, 0.0, 500.0, "under the cap")
            reach[int(gallery.id)] = limit
        # Samples of two primary galleries of one level, both away from their station, keep their distance.
        var settings: Dictionary = plan.settings
        for a: Dictionary in plan.galleries:
            for b: Dictionary in plan.galleries:
                if int(a.id) >= int(b.id) or int(a.parent) >= 0 or int(b.parent) >= 0 or a.level != b.level:
                    continue
                for da in range(60, int(reach[int(a.id)]), 20):
                    for db in range(60, int(reach[int(b.id)]), 20):
                        var gap := MineLayout.point_at(a, da).distance_to(MineLayout.point_at(b, db))
                        assert_gt(gap, float(settings.gallery_clearance_m) - 0.5,
                            "seed %d: galleries %d and %d too close" % [seed, a.id, b.id])


func test_limits_stop_under_thin_ground() -> void:
    var plan := MineLayout.generate(42, {}, MineLayout.STYLE_STRAIGHT)
    # The ground drops 1 m per 10 m away from the shaft: the first level's galleries stop near the surface.
    var cover := func(point: Vector3) -> float: return -point.y - Vector2(point.x, point.z).length() * 0.1
    var limits := MineLayout.limits(plan, cover)
    for gallery: Dictionary in plan.galleries:
        if int(gallery.level) == 0:
            assert_lt(float(limits[str(gallery.id)]), 120.0, "gallery %d stops before thin ground" % gallery.id)
    assert_eq(MineLayout.limits(plan, func(_p: Vector3) -> float: return NAN), {}, "unknown relief: measure later")


func test_faces_advance_up_to_the_limit() -> void:
    var plan := MineLayout.generate(42, {}, MineLayout.STYLE_STRAIGHT)
    var gallery: Dictionary = plan.galleries[0]
    var initial := float(gallery.initial_m)
    var limits := {"0": initial + 3.0}
    assert_false(MineLayout.face_open(plan, 0, {}, {}), "not measured yet: no face")
    assert_true(MineLayout.face_open(plan, 0, {}, limits))
    assert_almost_eq(float(MineLayout.dug(plan, {"0": 1.5}, limits)[0]), initial + 1.5, 1.0e-6)
    assert_almost_eq(float(MineLayout.dug(plan, {"0": 10.0}, limits)[0]), initial + 3.0, 1.0e-6, "capped")
    assert_false(MineLayout.face_open(plan, 0, {"0": 3.0}, limits), "at its limit the face is closed")


func test_graph_lists_the_mesher_volumes() -> void:
    var plan := MineLayout.generate(1234)
    var dug := MineLayout.dug(plan, {}, {})
    var graph := MineLayout.graph(plan, dug)
    assert_eq(graph.volumes[0].kind, "shaft")
    var tunnels := 0
    for volume: Dictionary in graph.volumes:
        assert_true(volume.has("a") and volume.has("b") and volume.has("size"), "every volume has a, b, size")
        if volume.kind == "tunnel":
            tunnels += 1
    assert_gt(tunnels, plan.galleries.size() - 1, "galleries meshed")
    assert_true(graph.bounds.has_point(Vector3(0, -float(plan.depth) + 1.0, 0)), "bounds hold the shaft's foot")


func test_contains_the_air() -> void:
    var plan := MineLayout.generate(42)
    var dug := MineLayout.dug(plan, {}, {})
    assert_true(MineLayout.contains(plan, dug, Vector3(0, -100, 0)), "in the shaft")
    assert_true(MineLayout.contains(plan, dug, plan.levels[0].station), "in a station")
    var gallery: Dictionary = plan.galleries[0]
    assert_true(MineLayout.contains(plan, dug, MineLayout.point_at(gallery, 10.0) + Vector3.UP), "in a gallery")
    assert_false(MineLayout.contains(plan, dug, Vector3(300, -5, 300)), "in the rock")
    assert_false(MineLayout.contains(plan, dug, MineLayout.point_at(gallery, float(gallery.initial_m) + 30.0)),
        "past the face")


func test_hole_is_a_round_cut() -> void:
    var hole := MinePlacement.make("m-1", Transform3D(Basis.IDENTITY, Vector3(0, 6.0e6, 0)), 20.0, 600.0)
    var openings := hole.openings()
    assert_eq(openings.size(), 1)
    var opening: Dictionary = openings[0]
    assert_false(bool(opening.snap), "edge stays on the pad")
    var polygon: PackedVector2Array = opening.polygon
    assert_eq(polygon.size(), MinePlacement.SIDES)
    for point in polygon:
        assert_almost_eq(point.length(), 20.0, 1.0e-6)
    assert_eq(Geometry2D.convex_hull(polygon).size() - 1, polygon.size(), "convex outline")
    assert_false(hole.refines_ground())
    var deeper := MinePlacement.make("m-1", Transform3D(Basis.IDENTITY, Vector3(0, 6.0e6, 0)), 20.0, 900.0)
    assert_eq(hole.signature(), deeper.signature(), "the depth does not change the cut")


func test_cells_meet_exactly() -> void:
    if not MineMesher.warm():
        pending("native mesher not built")
        return
    var plan := MineLayout.generate(42, {}, MineLayout.STYLE_STRAIGHT)
    var graph := MineLayout.graph(plan, MineLayout.dug(plan, {}, {}))
    var mesher := MineMesher.configure(graph)
    var size := MineCells.CELL_M
    # Two cells across the shaft wall at x = 0, under the ground.
    var west := MineMesher.build_cell(mesher, Vector3i(-1, -3, -1), size, 1.0)
    var east := MineMesher.build_cell(mesher, Vector3i(0, -3, -1), size, 1.0)
    assert_gt((west.wall as PackedVector3Array).size(), 300, "shaft wall in the west cell")
    assert_gt((east.wall as PackedVector3Array).size(), 300, "shaft wall in the east cell")
    # The edges both cells leave on their shared plane x = 0 are the same points.
    var seam_west := _on_plane(west, 0.0)
    var seam_east := _on_plane(east, 0.0)
    assert_gt(seam_west.size(), 4)
    assert_eq(seam_west.size(), seam_east.size(), "same seam points on both sides")
    for key: Vector3 in seam_west:
        assert_true(seam_east.has(key), "seam point %s on both sides" % key)
    # Nothing above the ground.
    var top := Vector3i(0, 0, -1)
    var surface := MineMesher.build_cell(mesher, top, size, 1.0)
    for point: Vector3 in surface.wall:
        assert_lte(point.y, 1.0e-6, "cut at the ground")
    # Normals face the air: the shaft's wall faces its axis.
    var normals: PackedVector3Array = east.wall_normals
    var points: PackedVector3Array = east.wall
    var inward := 0
    for index in range(0, points.size(), 7):
        var radial := Vector3(points[index].x, 0, points[index].z)
        if radial.length() > 15.0 and normals[index].dot(-radial.normalized()) > 0.0:
            inward += 1
    assert_gt(inward, 0, "wall normals point into the shaft")


func _on_plane(built: Dictionary, x: float) -> Dictionary:
    var out := {}
    for part in ["wall", "floor"]:
        for point: Vector3 in built[part]:
            if absf(point.x - x) < 1.0e-9:
                out[point.snapped(Vector3.ONE * 1.0e-6)] = true
    return out
