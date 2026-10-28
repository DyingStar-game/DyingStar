extends GutTest
## Version 8 network: chamber variety, 3D layout and steered walkable share. Its exact geometry is pinned by
## test_stargrot_v9.gd.


func before_all() -> void:
    CaveNetwork.warm()


func _profile(size_index: int, levels: int = 1, depth: float = 0.0) -> CaveProfile:
    var profile := CaveWorkbench.preset(size_index)
    profile.generator_version = 8
    profile.chamber_count = 4 + size_index
    profile.level_count = levels
    profile.depth_m = maxf(depth, 8.0 * (levels - 1))
    return profile


## First open point above the chamber's nominal floor centre: floors carry relief, so scan the column.
func _open_point(cave: Dictionary, room: Dictionary) -> Vector3:
    var a: Vector3 = room.a
    var height := -8.0
    while height < float(room.size.y) + 8.0:
        var point := a + Vector3.UP * height
        if float(cave.sampler.call("Sample", point)) > 0.3:
            return point
        height += 0.25
    return Vector3(INF, INF, INF)


func test_version_8_validates_its_limits() -> void:
    var spec := _profile(1).snapshot(5)
    assert_eq(CaveGenerator.validation_error(spec), "")
    for invalid in [0.1, 0.99, "0.7"]:
        spec.walkable_target = invalid
        assert_false(CaveGenerator.validation_error(spec).is_empty(), "walkable target %s refused" % str(invalid))
    var giant := _profile(4, 3, 290.0)
    assert_eq(CaveGenerator.validation_error(giant.snapshot(5)), "", "300 m chambers are allowed in version 8")
    giant.chamber_width_m = 330.0
    assert_false(CaveGenerator.validation_error(giant.snapshot(5)).is_empty(), "but not beyond 320 m")


func test_layout_is_seeded_and_spreads_chambers_in_three_dimensions() -> void:
    var spec := _profile(2, 2, 40.0).snapshot(31)
    var cave := CaveGenerator.build(spec)
    assert_eq(cave.error, "")
    if not cave.error.is_empty(): return
    assert_eq(cave.graph, CaveNetwork.layout(spec), "same seed, same network")
    assert_eq(cave.faces, CaveGenerator.build(spec).faces, "same seed, same surfaces")
    var xs: Array[float] = []
    var ys: Array[float] = []
    for room: Dictionary in cave.graph.rooms:
        xs.append(room.a.x)
        ys.append(room.a.y)
        var open := _open_point(cave, room)
        assert_true(is_finite(open.y) and CaveGenerator.contains(cave, open), "open chamber %s" % room.archetype)
    assert_gt(xs.max() - xs.min(), 20.0, "chambers leave the entrance axis")
    assert_gt(ys.max() - ys.min(), 8.0, "chambers sit at different depths")
    assert_ne(cave.faces, CaveGenerator.build(_profile(2, 2, 40.0).snapshot(32)).faces, "another seed, another cave")


func test_seeds_draw_many_archetypes_from_niches_to_cathedrals() -> void:
    var archetypes := {}
    var counts := {}
    var widest_ratio := 0.0
    var largest := 0.0
    for seed in [3, 17, 29, 41, 53, 67]:
        var graph := CaveNetwork.layout(_profile(3, 2, 60.0).snapshot(seed))
        counts[graph.rooms.size()] = true
        var smallest := INF
        var widest := 0.0
        for room: Dictionary in graph.rooms:
            archetypes[room.archetype] = true
            var width := 2.0 * maxf(float(room.size.x), float(room.size.z))
            smallest = minf(smallest, width)
            widest = maxf(widest, width)
        widest_ratio = maxf(widest_ratio, widest / smallest)
        largest = maxf(largest, widest)
    assert_gte(archetypes.size(), 6, "chamber families drawn: %s" % str(archetypes.keys()))
    assert_gt(counts.size(), 1, "the number of chambers varies with the seed")
    assert_gt(largest, 150.0, "cathedral-scale halls")
    assert_gt(widest_ratio, 10.0, "niches beside halls in one network")


func _layouts(style: String, size_index: int, seeds: Array) -> Array[Dictionary]:
    var graphs: Array[Dictionary] = []
    for seed in seeds:
        var profile := _profile(size_index, 2, 40.0)
        profile.network_style = style
        profile.chamber_count = 6
        var spec := profile.snapshot(seed)
        assert_eq(CaveGenerator.validation_error(spec), "", "%s %d valid" % [style, seed])
        graphs.append(CaveNetwork.layout(spec))
    return graphs


static func _stats(graphs: Array[Dictionary]) -> Dictionary:
    var widths: Array[float] = []
    var families := {}
    var rooms := 0
    var drop := 0.0
    for graph in graphs:
        var ys: Array[float] = []
        for room: Dictionary in graph.rooms:
            widths.append(2.0 * maxf(float(room.size.x), float(room.size.z)))
            families[room.archetype] = int(families.get(room.archetype, 0)) + 1
            ys.append(room.a.y)
        rooms += graph.rooms.size()
        drop = maxf(drop, ys.max() - ys.min())
    widths.sort()
    return {"median": widths[widths.size() / 2], "largest": widths.back(), "smallest": widths[0],
        "families": families, "rooms": float(rooms) / graphs.size(), "drop": drop}


func test_network_styles_shape_the_composition() -> void:
    var seeds := [5, 61, 777, 1234]
    var maze := _stats(_layouts("maze", 2, seeds))
    var ramiform := _stats(_layouts("ramiform", 2, seeds))
    var sponge := _stats(_layouts("spongework", 2, seeds))
    var branch := _stats(_layouts("branchwork", 2, seeds))
    var plain := _stats(_layouts("anastomotic", 2, seeds))
    var shafts := _stats(_layouts("shafts", 2, seeds))
    var fissures := int(maze.families.get("rift", 0)) + int(maze.families.get("alcove", 0))
    assert_gt(fissures, int(maze.rooms * seeds.size() * 0.6), "a maze is fissures and junctions: %s" % str(maze.families))
    assert_lt(maze.drop, 10.0, "a maze follows one level")
    assert_lt(plain.drop, 10.0, "braided tubes stay on their bedding plane")
    assert_gt(ramiform.median, maze.median * 2.0, "ramiform chambers dwarf maze junctions")
    assert_gt(sponge.rooms, branch.rooms, "spongework is many small linked cavities")
    assert_gt(int(shafts.families.get("chimney", 0)), 0, "a cascade of pits has its chimneys")
    assert_gt(shafts.drop, 25.0, "and descends")
    for graph in _layouts("auto", 1, [3, 4, 5, 6, 7, 8, 9, 10]):
        assert_true(CaveLayoutV8.STYLES.has(str(graph.style)), "auto draws a known pattern")


func test_giants_and_niches_coexist_whatever_the_authored_size() -> void:
    var stats := _stats(_layouts("auto", 1, range(20, 44)))
    var scale := CaveWorkbench.preset(1).chamber_width_m
    assert_gt(stats.largest, scale * 1.8, "now and then a giant beyond the authored size")
    assert_lt(stats.smallest, 8.0, "and niches a few metres across")


func test_walkable_share_follows_the_target() -> void:
    var means := {}
    for target in [0.35, 0.85]:
        var total := 0.0
        for seed in [101, 202, 303, 404, 505]:
            var profile := _profile(1, 2, 24.0)
            profile.walkable_target = target
            var cave := CaveGenerator.build(profile.snapshot(seed))
            assert_eq(cave.error, "")
            if not cave.error.is_empty(): return
            total += float(cave.walkable_ratio)
        means[target] = total / 5.0
    assert_gt(float(means[0.85]), float(means[0.35]) + 0.15, "measured means %s" % str(means))
    assert_between(float(means[0.85]), 0.6, 1.0)


func test_entrance_gallery_always_reaches_the_first_chamber_on_foot() -> void:
    for seed in [7, 77, 777, 7777]:
        var cave := CaveGenerator.build(_profile(2, 2, 30.0).snapshot(seed))
        assert_eq(cave.error, "")
        if not cave.error.is_empty(): return
        assert_eq(CavePopulation.accessible_entry_error(cave), "", "capsule fits the first gallery")
        var doorway: Vector3 = cave.graph.links[1].b
        var nearest := INF
        for point in cave.reach_points:
            nearest = minf(nearest, point.distance_to(doorway))
        assert_lt(nearest, float(cave.graph.cell_m) * 2.0 + 1.0, "seed %d: first chamber reached" % seed)
        assert_false(cave.entry.is_empty(), "the vestibule joins an open portal")


func test_obstacles_bar_the_way_but_rooms_stay_physical() -> void:
    var kinds := {}
    for seed in [5, 6, 8, 9]:
        var profile := _profile(1, 2, 24.0)
        profile.walkable_target = 0.3
        var graph := CaveNetwork.layout(profile.snapshot(seed))
        for link: Dictionary in graph.links:
            kinds[link.get("kind", "walk")] = true
    assert_true(kinds.has("pit") or kinds.has("perched") or kinds.has("shaft"), "kinds: %s" % str(kinds.keys()))
    var cave := CaveGenerator.build(_profile(1).snapshot(5))
    var root := CavePreviewBuilder.instantiate(cave, null, false, true)
    add_child_autofree(root)
    await get_tree().physics_frame
    await get_tree().physics_frame
    var open := _open_point(cave, cave.graph.rooms[0])
    assert_true(is_finite(open.y), "the first chamber is open")
    var hit := root.get_world_3d().direct_space_state.intersect_ray(
        PhysicsRayQueryParameters3D.create(open, open + Vector3.DOWN * 20))
    assert_false(hit.is_empty(), "the chamber floor is a collision surface")
    assert_lte(int(cave.cells), 9000000, "sparse lattice budget")
