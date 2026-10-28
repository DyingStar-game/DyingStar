extends GutTest
## Version 9: six more chamber families, eroded galleries, natural light shafts, and version 8 left untouched.

## V8 reference geometry after the 2026-10-19 seam repair (complete portal edges and floor).
## Layout/density remain v8; only the previously incomplete connector was repaired.
const V8 := {"8,1,104729": "dfb98eef38b73602", "8,2,7": "7c94ef7d491eb353", "8,0,73": "a56a4d0bdfe4f89e"}
const NEW_FAMILIES := ["dome", "gallery", "terraced", "forest", "basin", "balcony"]


class Flat extends PlanetData:
    func crack_aware_surface_dist(_direction: Vector3, _nside: int = -1, _spacing: float = 0.0) -> float:
        return radius


func before_all() -> void:
    CaveNetwork.warm()


func _profile(size_index: int, seed_style: String = "auto") -> CaveProfile:
    var profile := CaveWorkbench.preset(size_index)
    profile.chamber_count = 4 + size_index
    profile.level_count = 2
    profile.depth_m = maxf(profile.depth_m, 24.0 + 20.0 * size_index)
    profile.network_style = seed_style
    return profile


func _digest(faces: PackedVector3Array) -> String:
    var hashing := HashingContext.new()
    hashing.start(HashingContext.HASH_SHA256)
    hashing.update(var_to_bytes(faces))
    return hashing.finish().hex_encode().substr(0, 16)


## Lowest air above [param point] in its column (the floor), or INF.
func _floor(cave: Dictionary, point: Vector3, below: float = 12.0, above: float = 12.0) -> float:
    var y := point.y - below
    while y < point.y + above:
        if float(cave.sampler.call("Sample", Vector3(point.x, y, point.z))) > 0.0:
            return y
        y += 0.1
    return INF


func test_version_8_keeps_its_exact_geometry() -> void:
    for key: String in V8:
        var parts := key.split(",")
        var profile := CaveWorkbench.preset(int(parts[1]))
        profile.generator_version = int(parts[0])
        var spec := profile.snapshot(int(parts[2]))
        assert_false(spec.has("gallery_noise") or spec.has("light_shafts"), "version 8 definitions take no v9 keys")
        var cave := CaveGenerator.build(spec)
        assert_eq(str(cave.get("error", "")), "", key)
        if str(cave.get("error", "")).is_empty():
            assert_eq(_digest(cave.faces), V8[key], "v8 geometry unchanged by version 9")


func test_new_definitions_use_version_9_and_validate_erosion_and_shafts() -> void:
    var profile := CaveWorkbench.preset(1)
    assert_eq(profile.generator_version, CaveGenerator.VERSION)
    assert_eq(CaveGenerator.VERSION, 9)
    var spec := profile.snapshot(5)
    assert_eq(CaveGenerator.validation_error(spec), "")
    assert_almost_eq(float(spec.gallery_noise), 0.6, 0.0001)
    assert_eq(int(spec.light_shafts), 1)
    for invalid in [-0.1, 1.5, "0.5"]:
        var broken := spec.duplicate()
        broken.gallery_noise = invalid
        assert_false(CaveGenerator.validation_error(broken).is_empty(), "gallery noise %s refused" % str(invalid))
    for invalid in [-1, CaveLayoutV8.MAX_LIGHT_SHAFTS + 1, 1.0]:
        var broken := spec.duplicate()
        broken.light_shafts = invalid
        assert_false(CaveGenerator.validation_error(broken).is_empty(), "%s light shafts refused" % str(invalid))


func test_seeds_draw_the_thirteen_families_with_their_own_shapes() -> void:
    var families := {}
    var columns := 0
    for style in ["ramiform", "branchwork", "anastomotic", "spongework"]:
        for seed in [3, 17, 29, 41, 53]:
            var graph := CaveNetwork.layout(_profile(2, style).snapshot(seed))
            for index in graph.rooms.size():
                var room: Dictionary = graph.rooms[index]
                families[room.archetype] = true
                match str(room.archetype):
                    "terraced":
                        assert_gt(float(room.terrace), 0.5, "terraces have a step")
                        assert_gt(Vector2(room.tilt).length(), 0.1, "and descend a slope")
                    "basin":
                        assert_gt(float(room.basin), 0.9, "a basin sinks into the floor")
                    "dome":
                        assert_gt(float(room.size.y), maxf(room.size.x, room.size.z) * 0.9, "a dome rises past its radius")
                    "gallery":
                        assert_gt(float(room.size.z), float(room.size.x) * 2.5, "a long hall")
            for pillar: Dictionary in graph.pillars:
                for room: Dictionary in graph.rooms:
                    if room.archetype == "forest" and Vector2(pillar.a.x - room.a.x, pillar.a.z - room.a.z).length() < float(room.size.x):
                        columns += 1
    for family in CaveLayoutV8.ARCHETYPES_V9:
        assert_true(families.has(family), "family %s drawn: %s" % [family, str(families.keys())])
    assert_gt(columns, 8, "forest rooms stand on columns")


## Version 9 volumes meet in fillets: each smooth union changes the density by a quarter of its radius at most,
## a few volumes meeting at one point by a little more (so cover and walkability barely move), and columns stay
## thick enough to mesh round.
func test_volumes_meet_in_bounded_fillets_and_columns_stay_round() -> void:
    var spec := _profile(2, "ramiform").snapshot(17)
    var graph := CaveNetwork.layout(spec)
    var blend := float(graph.get("blend_m", 0.0))
    assert_gt(blend, 0.9, "version 9 blends its volumes")
    assert_lte(blend, 2.5)
    var sharp := graph.duplicate()
    sharp.blend_m = 0.0
    var smooth: RefCounted = CaveNetwork._mesher.new()
    smooth.call("Configure", graph)
    var exact: RefCounted = CaveNetwork._mesher.new()
    exact.call("Configure", sharp)
    var rng := RandomNumberGenerator.new()
    rng.seed = 99
    var bounds: AABB = graph.bounds
    var largest := 0.0
    var changed := 0
    for sample in 4000:
        var point := bounds.position + Vector3(rng.randf(), rng.randf(), rng.randf()) * bounds.size
        var delta := float(smooth.call("Sample", point)) - float(exact.call("Sample", point))
        largest = maxf(largest, absf(delta))
        changed += int(absf(delta) > 0.01)
    assert_lte(largest, blend * 0.6, "a fillet moves the surface by a fraction of its radius")
    assert_gt(changed, 0, "fillets do round the joints")
    var thinnest := CaveLayoutV8.COLUMN_MIN_CELLS * clampf(float(spec.width_m) / 4.0, 1.0, 1.5)
    for pillar: Dictionary in graph.pillars:
        if pillar.kind == "pillar":
            assert_gte(float(pillar.size.x), thinnest - 0.0001, "a column at least %.1f m thick" % thinnest)
    var legacy := CaveWorkbench.preset(1)
    legacy.generator_version = 8
    assert_false(CaveNetwork.layout(legacy.snapshot(7)).has("blend_m"), "version 8 keeps its exact union")


## A mesher holding [param volumes] alone, configured like [param graph].
func _alone(graph: Dictionary, volumes: Array) -> RefCounted:
    var single := graph.duplicate()
    single.volumes = volumes
    var mesher: RefCounted = CaveNetwork._mesher.new()
    mesher.call("Configure", single)
    return mesher


## Lowest air in [param mesher]'s column at [param point], scanning up from [param below] under it.
func _air_from(mesher: RefCounted, point: Vector3, below: float, above: float) -> float:
    var y := point.y - below
    while y < point.y + above:
        if float(mesher.call("Sample", Vector3(point.x, y, point.z))) > 0.0:
            return y
        y += 0.05
    return INF


func test_basin_and_terraces_reshape_the_floor_not_the_vault() -> void:
    var found := {}
    for seed in range(1, 80):
        if found.size() == 2:
            break
        var graph := CaveNetwork.layout(_profile(2, "anastomotic" if seed % 2 == 0 else "branchwork").snapshot(seed))
        for room: Dictionary in graph.rooms:
            if found.has(room.archetype) or minf(room.size.x, room.size.z) <= 8.0:
                continue
            var a: Vector3 = room.a
            var turn := Basis(Vector3.UP, float(room.yaw))
            var mesher := _alone(graph, [room])
            if room.archetype == "basin":
                var middle := _air_from(mesher, a, float(room.basin) + 3.0, 6.0)
                assert_lt(middle, a.y - float(room.basin) * 0.6, "the basin's middle lies below the floor plane")
                var vault := a.y + 1.0
                while float(mesher.call("Sample", Vector3(a.x, vault, a.z))) > 0.0:
                    vault += 0.1
                assert_gt(vault, a.y + float(room.size.y) * 0.7, "the vault keeps its height over the basin")
                found.basin = true
            elif room.archetype == "terraced" and float(room.terrace) >= 1.0:
                # Down the slope, relative to the tilted plane: shelves fall behind it, risers catch up. A plain slope
                # would only show the floor relief.
                var tilt: Vector2 = room.tilt
                var down := Vector3(tilt.x, 0, tilt.y).normalized()
                var offsets: Array[float] = []
                for step in 25:
                    var t := lerpf(-0.45, 0.45, step / 24.0) * minf(room.size.x, room.size.z)
                    var plane := a.y + tilt.length() * t
                    var height := _air_from(mesher, Vector3(a.x, plane, a.z) + turn * (down * t), float(room.terrace) + 3.0, 4.0)
                    if is_finite(height):
                        offsets.append(height - plane)
                assert_gt(offsets.max() - offsets.min(), float(room.terrace) * 0.55, "shelves and risers: %s" % str(offsets))
                found.terraced = true
    assert_eq(found.size(), 2, "a basin and a terraced room were checked: %s" % str(found.keys()))


## One straight, level gallery of 20 segments, eroded by [param erode], alone in a mesher.
func _gallery(erode: float) -> RefCounted:
    var volumes: Array[Dictionary] = []
    for index in 20:
        var volume := {"kind": "tunnel", "a": Vector3(0, 0, index * 5.0), "b": Vector3(0, 0, index * 5.0 + 5.0),
            "size": Vector3(3.0, 5.0, 3.0), "amp": 0.3, "freq": 0.2, "continues_a": index > 0, "continues_b": index < 19,
            "grade_reach": true}
        if erode > 0.0:
            volume.merge({"erode_a": erode, "erode_b": erode})
        volumes.append(volume)
    return _alone({"roughness": 0.5, "phase": 0.0, "v8": true, "noise_seed": 1234, "cell_m": 1.5,
        "bounds": AABB(Vector3(-20, -5, -5), Vector3(40, 25, 110))}, volumes)


func test_gallery_erosion_varies_sections_and_keeps_the_floor() -> void:
    var spreads := {}
    for erode in [0.0, 0.9]:
        var mesher := _gallery(erode)
        var widths: Array[float] = []
        var floors: Array[float] = []
        var headroom := INF
        for step in range(10, 91, 2):
            var probe := Vector3(0.0, 1.5, step)
            var width := 0.0
            for direction in [Vector3.RIGHT, Vector3.LEFT]:
                var reach := 0.0
                while reach < 12.0 and float(mesher.call("Sample", probe + direction * reach)) > 0.0:
                    reach += 0.05
                width += reach
            widths.append(width)
            floors.append(_air_from(mesher, Vector3(0, 0, step), 3.0, 3.0))
            var roof := 0.5
            while float(mesher.call("Sample", Vector3(0, roof, step))) > 0.0:
                roof += 0.05
            headroom = minf(headroom, roof)
        var mean := 0.0
        for width in widths:
            mean += width / widths.size()
        var spread := 0.0
        for width in widths:
            spread += absf(width - mean) / widths.size()
        spreads[erode] = spread / mean
        assert_lt(floors.max() - floors.min(), 0.15, "erode %.1f: one level floor" % erode)
        assert_gt(headroom, 2.4, "erode %.1f: standing headroom all along (%.2f)" % [erode, headroom])
        assert_gt(widths.min(), 2.4, "erode %.1f: never narrower than a walker needs" % erode)
    assert_gt(float(spreads[0.9]), float(spreads[0.0]) * 2.0 + 0.04, "erosion narrows and widens it: %s" % str(spreads))


func test_eroded_networks_keep_their_entrance_and_walkable_share() -> void:
    for noise in [0.0, 0.9]:
        var profile := _profile(1, "branchwork")
        profile.gallery_noise = noise
        profile.light_shafts = 0
        var cave := CaveGenerator.build(profile.snapshot(77))
        assert_eq(str(cave.error), "")
        if not str(cave.error).is_empty():
            return
        assert_eq(CavePopulation.accessible_entry_error(cave), "", "noise %.1f: the capsule fits the entrance gallery" % noise)
        assert_gt(float(cave.walkable_ratio), 0.45, "noise %.1f: still largely walkable (%.2f)" % [noise, cave.walkable_ratio])

func test_walkable_share_tracks_the_target() -> void:
    var means := {}
    for target in [0.4, 0.8]:
        var total := 0.0
        for seed in [101, 202, 303, 404, 505, 606]:
            var profile := _profile(1)
            profile.walkable_target = target
            var cave := CaveGenerator.build(profile.snapshot(seed))
            assert_eq(cave.error, "")
            if not cave.error.is_empty():
                return
            total += float(cave.walkable_ratio)
        means[target] = total / 6.0
    assert_gt(float(means[0.8]), 0.62, "measured means %s" % str(means))
    assert_gt(float(means[0.8]), float(means[0.4]) + 0.1, "measured means %s" % str(means))


## A cave of [param size_index] with light shafts: the first seed of [param seeds] that placed one, with the
## profile that made it.
func _lit(size_index: int, seeds: Array) -> Dictionary:
    for seed in seeds:
        var profile := _profile(size_index)
        profile.light_shafts = 3
        profile.entrance_type = "ramp"
        var spec := profile.snapshot(seed)
        if CaveNetwork.layout(spec).get("lights", []).is_empty():
            continue
        var cave := CaveGenerator.build(spec)
        if str(cave.error).is_empty():
            cave.profile = profile
            return cave
    return {}


func test_light_shafts_rise_from_a_vault_to_the_lattice_top() -> void:
    var cave := _lit(2, range(500, 520))
    assert_false(cave.is_empty(), "some seed places a light shaft")
    if cave.is_empty():
        return
    var graph: Dictionary = cave.graph
    var top := (graph.bounds as AABB).end.y
    assert_eq((cave.lights as Array).size(), (graph.lights as Array).size(), "one open loop per shaft")
    for index in graph.lights.size():
        var light: Dictionary = graph.lights[index]
        var loop: PackedVector3Array = cave.lights[index]
        assert_gt(loop.size(), 5, "an open loop")
        var center: Vector2 = light.center
        for point in loop:
            assert_gt(point.y, top - 0.0001, "on the top sample plane")
            assert_lt(Vector2(point.x, point.z).distance_to(center), float(light.radius) + float(graph.cell_m) * 2.0,
                "around its own axis")
        var foot := float(light.foot)
        var open := true
        var y := foot + 0.5
        while y < top - 1.0:
            open = open and float(cave.sampler.call("Sample", Vector3(center.x, y, center.y))) > 0.0
            y += 0.5
        assert_true(open, "air all the way up the shaft from its foot in the vault")
        # Under its foot the chamber's air, then its floor (or a rock bridge across it): never a hole.
        var below := foot - 0.1
        while below > foot - 80.0 and float(cave.sampler.call("Sample", Vector3(center.x, below, center.y))) > 0.0:
            below -= 0.1
        assert_gt(below, foot - 80.0, "a floor lies under the shaft")
        assert_lt(below, foot - 0.5, "the shaft opens into the chamber's air, above its floor")


func test_light_shafts_open_the_ground_once_fitted() -> void:
    var cave := _lit(2, range(500, 520))
    if cave.is_empty():
        fail_test("no seed placed a light shaft")
        return
    var site := CavePlacement.new()
    site.format_version = 2
    site.placement_id = "light-unit"
    site.planet_name = "synthetic"
    site.terrain_version = "v"
    site.planet_radius_m = 6356000.0
    site.seed = int(cave.spec.seed)
    site.profile = cave.profile
    site.cover_m = 3.0
    var data := Flat.new()
    data.radius = site.planet_radius_m
    data.planet_name = "synthetic"
    data.chunk_data_version = "v"
    var fit := CavePortal.fit(data, site, cave)
    assert_eq(str(fit.error), "")
    site.apply_fit(fit)
    assert_eq(site.light_wells.size(), (cave.graph.lights as Array).size(), "one pinned well per shaft")
    assert_eq(site.definition_error(), "")
    var signature := site.signature()
    var lights: Array[Dictionary] = []
    for opening in site.openings():
        if opening.kind == "light":
            lights.append(opening)
    assert_eq(lights.size(), site.light_wells.size())
    var entrance := CaveEntrance.build(data, site, cave)
    var walls: PackedVector3Array = entrance.wall.vertices
    var origin := site.network_origin()
    var frame := site.surface_transform()
    for opening in lights:
        var well := site.light_wells[int(opening.light)]
        assert_gt(-float(opening.floor_depth), -float(fit.depth) - 0.001, "the top plane lies above the network origin")
        var loop: PackedVector3Array = cave.lights[int(opening.light)]
        for point in loop:
            var nearest := INF
            for vertex in walls:
                nearest = minf(nearest, vertex.distance_squared_to(point + origin))
            assert_lt(nearest, 0.00000001, "the shaft walls keep every lattice seam vertex")
        # Ground cut inside the rim, kept beyond it; presence in the column.
        var terrain := PackedVector3Array()
        for x in range(-8, 8):
            for z in range(-8, 8):
                var corners: Array[Vector3] = []
                for offset: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
                    corners.append((frame * Vector3(well.x + x + offset.x, 0, well.y + z + offset.y)))
                terrain.append_array([corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]])
        var cut := CaveTerrainCut.collision_faces(terrain, Vector3.ZERO, [site])
        var axis := frame * Vector3(well.x, 0, well.y)
        var up := frame.basis.y.normalized()
        var beside := frame * Vector3(well.x + well.z * 2.5, 0, well.y)
        assert_false(_crosses(cut, axis + up * 5.0, axis - up * 5.0), "the hole opens the ground over the shaft")
        assert_true(_crosses(cut, beside + up * 5.0, beside - up * 5.0), "the ground beside the hole stays")
        assert_true(CaveEntrance.contains(data, site, axis - up * 2.0), "the shaft column is cave space")
    assert_eq(CaveEntrance.site_error(data, site, cave), "")
    site.light_wells = PackedVector4Array()
    assert_ne(site.signature(), signature, "cache identity follows the pinned wells")
    var broken: CavePlacement = site.duplicate(true)
    broken.light_wells = PackedVector4Array([Vector4(0, 0, 50.0, 0)])
    assert_false(broken.definition_error().is_empty(), "an absurd well is refused")


func _crosses(faces: PackedVector3Array, from: Vector3, to: Vector3) -> bool:
    for index in range(0, faces.size(), 3):
        if Geometry3D.segment_intersects_triangle(from, to, faces[index], faces[index + 1], faces[index + 2]) != null:
            return true
    return false


func test_version_9_ends_without_crawls_and_version_8_keeps_them() -> void:
    for version in [8, 9]:
        var profile := _profile(1)
        profile.generator_version = version
        profile.crawl_count = 4
        profile.light_shafts = 0
        var spec := profile.snapshot(19)
        var cave := CaveGenerator.build(spec)
        assert_eq(str(cave.error), "")
        if not str(cave.error).is_empty():
            return
        assert_eq(cave.has("crawl_rings"), version == 8, "terminal squeezes: version %d" % version)
        if version == 9:
            assert_almost_eq((cave.graph.bounds as AABB).end.z, float(spec.length_m), 0.01, "the network runs to its end")


func test_pits_mostly_leave_the_way_open() -> void:
    var barring := 0
    var passes := {}
    var bridge := {}
    var ledge := {}
    for seed in range(1, 81):
        var profile := _profile(seed % 3)
        profile.light_shafts = 0
        var spec := profile.snapshot(seed)
        var graph := CaveNetwork.layout(spec)
        for link: Dictionary in graph.links:
            barring += int(link.kind == "pit")
        for pit: Dictionary in graph.pits:
            passes[pit.pass] = int(passes.get(pit.pass, 0)) + 1
            if bridge.is_empty() and pit.pass == "bridge":
                bridge = {"spec": spec, "pit": pit, "span": graph.spans[0]}
            if ledge.is_empty() and pit.pass == "ledge":
                ledge = {"spec": spec, "pit": pit}
    assert_true(passes.has("bridge") and passes.has("ledge"), "both passable pits occur: %s" % str(passes))
    assert_lt(barring, int(passes.get("bridge", 0)) + int(passes.get("ledge", 0)) + 6,
        "barring pits stay rare: %d against %s" % [barring, str(passes)])
    if not bridge.is_empty():
        var cave := CaveGenerator.build(bridge.spec)
        var span: Dictionary = bridge.span
        var middle: Vector3 = ((span.a as Vector3) + (span.b as Vector3)) * 0.5 + Vector3.UP * 0.15
        var across := ((span.b as Vector3) - (span.a as Vector3)).cross(Vector3.UP).normalized()
        assert_gt(float(cave.sampler.call("Sample", middle + Vector3.UP * 0.8)), 0.0, "air over the bridge")
        assert_lt(float(cave.sampler.call("Sample", middle + Vector3.DOWN * 0.6)), 0.0, "a rock deck under the way")
        var hole := middle + across * (float(span.size.x) + 0.6) + Vector3.DOWN * 2.0
        assert_gt(float(cave.sampler.call("Sample", hole)), 0.0, "the pit opens beside the deck")
    if not ledge.is_empty():
        var cave := CaveGenerator.build(ledge.spec)
        var pit: Dictionary = ledge.pit
        var away: Vector3 = (pit.gallery as Vector3) - ((pit.center as Vector3) - (pit.gallery as Vector3)).normalized() \
            * float(pit.width) * 0.2
        assert_lt(absf(_floor(cave, away) - (pit.gallery as Vector3).y), 1.5, "a floor beside the hole")
        assert_lt(_floor(cave, pit.center, 1.0, 1.0), (pit.center as Vector3).y - 0.9, "the hole sinks below it")


func test_approach_hollow_frames_a_porch_on_flat_ground() -> void:
    for size_index in 4:
        for seed in [5, 77, 4242]:
            var shape := CaveApproach.shape(CaveWorkbench.preset(size_index).snapshot(seed), 24.0, 18.0)
            var outline: PackedVector2Array = shape.outline
            var area := 0.0
            for index in outline.size():
                area += outline[index].cross(outline[(index + 1) % outline.size()]) * 0.5
            var tiled := 0.0
            for part: PackedVector2Array in shape.parts:
                for index in part.size():
                    tiled += part[index].cross(part[(index + 1) % part.size()]) * 0.5
            assert_almost_eq(absf(tiled), absf(area), absf(area) * 0.001, "convex parts tile the rim exactly")
            var crossing := false
            for i in outline.size():
                for j in range(i + 2, outline.size()):
                    if not (i == 0 and j == outline.size() - 1) and Geometry2D.segment_intersects_segment(outline[i],
                            outline[(i + 1) % outline.size()], outline[j], outline[(j + 1) % outline.size()]) != null:
                        crossing = true
            assert_false(crossing, "a simple rim (size %d, seed %d)" % [size_index, seed])
    var site := CavePlacement.new()
    site.format_version = 2
    site.placement_id = "approach-unit"
    site.planet_name = "synthetic"
    site.terrain_version = "v"
    site.planet_radius_m = 6356000.0
    site.seed = 5
    site.profile = CaveWorkbench.preset(0)
    site.profile.light_shafts = 0
    site.cover_m = 3.0
    var data := Flat.new()
    data.radius = site.planet_radius_m
    data.planet_name = "synthetic"
    data.chunk_data_version = "v"
    var cave := CaveGenerator.build(site.profile.snapshot(site.seed))
    var fit := CavePortal.fit(data, site, cave)
    assert_eq(str(fit.error), "")
    site.apply_fit(fit)
    var kinds := []
    for opening in site.openings():
        kinds.append(opening.kind)
    assert_eq(kinds.slice(0, 2), ["porch", "approach"], "a porch diving into flat ground opens in a hollow")
    var m := CaveApproach.model(site.profile.snapshot(site.seed), site.portal_descent_deg, site.portal_axis_m)
    var frame := site.surface_transform()
    var z := float(m.back) * 0.5
    var floor_point := frame * Vector3(0.0, CaveApproach.height(m, 0.0, z) + 1.0, z)
    assert_true(CaveEntrance.contains(data, site, floor_point), "the hollow is cave space, held up for no one")
    var terrain := PackedVector3Array()
    for x in range(-3, 3):
        for row in range(-3, 3):
            var corners: Array[Vector3] = []
            for offset: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
                corners.append(frame * Vector3(x + offset.x, 0, z + row + offset.y))
            terrain.append_array([corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]])
    var up := frame.basis.y.normalized()
    var cut := CaveTerrainCut.collision_faces(terrain, Vector3.ZERO, [site])
    assert_false(_crosses(cut, frame * Vector3(0, 5, z), frame * Vector3(0, -5, z)), "no ground left over the hollow")
    assert_eq(CaveEntrance.site_error(data, site, cave), "")


func test_surfaces_are_smooth_shaded() -> void:
    var profile := _profile(1)
    profile.light_shafts = 0
    var cave := CaveGenerator.build(profile.snapshot(11))
    var normals: PackedVector3Array = cave.wall.normals
    var unit := 0
    var blended := 0
    for index in range(0, normals.size(), 3):
        for corner in 3:
            unit += int(absf(normals[index + corner].length() - 1.0) < 0.001)
        blended += int(not normals[index].is_equal_approx(normals[index + 1]) or not normals[index].is_equal_approx(normals[index + 2]))
    assert_eq(unit, normals.size(), "unit normals")
    assert_gt(blended, normals.size() / 3 * 0.8, "faces blend into their neighbours: no facets")
