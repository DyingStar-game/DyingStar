extends GutTest
## Version 8 entrances on synthetic relief: porches bored into cliffs, slopes and flat ground, dolines.


class Relief extends PlanetData:
    var frame: Transform3D
    var shape: String

    func height(x: float, z: float) -> float:
        match shape:
            "cliff": return 70.0 * smoothstep(0.0, 3.0, z)
            "slope": return maxf(0.0, z) * tan(deg_to_rad(30.0))
            "cross_slope": return 3.0 * z + 0.8 * x + 0.12 * x * x
            "ridge": return maxf(0.0, 45.0 - absf(z - 45.0))  # a 45 m crest, falling again beyond it
        return 0.0

    func crack_aware_surface_dist(direction: Vector3, _nside: int = -1, _spacing: float = 0.0) -> float:
        var local := frame.affine_inverse() * (direction * radius)
        return radius + height(local.x, local.z)


func before_all() -> void:
    CaveNetwork.warm()


func _fitted(shape: String, kind: String, width: float, height: float, cave_seed: int = 4242) -> Dictionary:
    var profile := CaveWorkbench.preset(1)
    profile.entrance_type = kind
    profile.entrance_width_m = width
    profile.entrance_height_m = height
    profile.chamber_height_m = maxf(profile.chamber_height_m, height)
    var site := CavePlacement.new()
    site.format_version = 2
    site.placement_id = "portal-unit"
    site.planet_name = "synthetic"
    site.terrain_version = "v"
    site.planet_radius_m = 6356000.0
    site.profile = profile
    site.seed = cave_seed
    site.cover_m = 3.0
    var data := Relief.new()
    data.radius = site.planet_radius_m
    data.planet_name = "synthetic"
    data.chunk_data_version = "v"
    data.shape = shape
    data.frame = site.surface_transform()
    var cave := CaveGenerator.build(profile.snapshot(site.seed))
    assert_eq(str(cave.error), "")
    var fit := CavePortal.fit(data, site, cave)
    assert_eq(str(fit.error), "", "%s %s fits" % [shape, kind])
    if str(fit.error).is_empty():
        site.apply_fit(fit)
    return {"site": site, "data": data, "cave": cave}


## Synthetic ground as 1 m triangles around the site, in planet coordinates.
func _terrain(data: Relief, site: CavePlacement, extent: float, reach: float) -> PackedVector3Array:
    var faces := PackedVector3Array()
    var frame := site.surface_transform()
    for x in range(-int(extent), int(extent)):
        for z in range(-int(extent), int(reach)):
            var corners: Array[Vector3] = []
            for offset: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
                var direction := (frame * Vector3(x + offset.x, 0, z + offset.y)).normalized()
                corners.append(direction * data.crack_aware_surface_dist(direction))
            faces.append_array([corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]])
    return faces


func _hits(faces: PackedVector3Array, from: Vector3, to: Vector3) -> bool:
    for index in range(0, faces.size(), 3):
        if Geometry3D.segment_intersects_triangle(from, to, faces[index], faces[index + 1], faces[index + 2]) != null:
            return true
    return false


func _check_porch(case: Dictionary, width: float, height: float) -> void:
    var site: CavePlacement = case.site
    var data: Relief = case.data
    var frame := site.surface_transform()
    var terrain := _terrain(data, site, 40.0, 60.0)
    var entrance := CaveEntrance.build(data, site, case.cave)
    # Rock is the cut ground plus the entrance's own surfaces (a version 9 approach hollow replaces the ground).
    var cut := CaveTerrainCut.collision_faces(terrain, Vector3.ZERO, [site])
    for vertex in entrance.faces:
        cut.append(frame * vertex)
    var axes := CavePortal.porch_axes(site.portal_descent_deg)
    var middle: Vector3 = axes.up * height * 0.4
    var outside: Vector3 = middle - (axes.forward as Vector3) * 6.0
    var inside: Vector3 = middle + (axes.forward as Vector3) * site.portal_axis_m * 0.8
    var side := Vector3.RIGHT * (float(site.openings()[0].width) * 0.5 + 2.0)  # beyond the eroded outline too
    assert_false(_hits(cut, frame * outside, frame * inside), "the mouth is open")
    assert_true(_hits(cut, frame * (outside + side), frame * (inside + side + axes.forward * 20.0)), "rock beside it stays")
    var highest := -INF
    for vertex in entrance.wall.vertices:
        highest = maxf(highest, vertex.y - CaveEntrance.ground_in_frame(data, frame, vertex.x, vertex.z).y)
    # Only the rim's lip (CaveEntrance.seal_rim) stands above the relief, by its own height at most.
    assert_lte(highest, CaveEntrance.LIP_M + 0.01, "gallery walls never rise above the relief, the rim's lip aside")
    assert_eq(CaveEntrance.site_error(data, site, case.cave), "")
    var rings: Array = CavePortal.build_porch(data, site, site.openings()[0]).rings
    var last: PackedVector3Array = rings.back()
    var network: PackedVector3Array = case.cave.rings[0]
    for point in network:
        var nearest := INF
        for candidate in last:
            nearest = minf(nearest, candidate.distance_to(point + site.network_origin()))
        assert_lt(nearest, 0.000001, "every network vertex remains on shared seam")
    for point in last:
        var nearest := INF
        for segment in network.size() - 1:
            var on_edge := Geometry3D.get_closest_point_to_segment(point, network[segment] + site.network_origin(),
                network[segment + 1] + site.network_origin())
            nearest = minf(nearest, point.distance_to(on_edge))
        assert_lt(nearest, 0.000001, "extra seam points lie on the network ring")



func test_porch_bores_horizontally_into_a_cliff() -> void:
    var case := _fitted("cliff", "ramp", 8.0, 14.0)
    var site: CavePlacement = case.site
    assert_eq(site.portal_descent_deg, 0.0, "straight into the wall")
    assert_lt(site.portal_axis_m, 6.0, "covered almost at once by a vertical face")
    assert_eq(site.mouth_depth(), 0.0, "the network continues at the mouth's level")
    _check_porch(case, 8.0, 14.0)


func test_cross_slope_porch_floor_covers_the_whole_cut_from_its_front_cap() -> void:
    var case := _fitted("cross_slope", "ramp", 7.0, 12.0, 4321)
    var site: CavePlacement = case.site
    var opening: Dictionary = site.openings()[0]
    assert_false(opening.approach, "steep flank directly bored through the terrain")
    var porch := CavePortal.build_porch(case.data, site, opening)
    var forward: Vector3 = CavePortal.porch_axes(site.portal_descent_deg).forward
    var first: PackedVector3Array = porch.rings[0]
    for endpoint in [first[0], first[-1]]:
        assert_almost_eq(endpoint.dot(forward), -float(opening.axis.y), 0.000001,
            "both feet meet the cut's front cap even when the ground meets the sides at different depths")
    var missing := 0
    for x in range(-6, 7):
        for z in range(1, 9):
            var point := Vector3(x * 0.5, 0, z * 0.25)
            missing += int(not _hits(porch.floor.vertices, point + Vector3.UP, point + Vector3.DOWN))
    assert_eq(missing, 0, "no exposed triangle between the cap and the diagonally clipped sill")
    var rock: PackedVector3Array = porch.wall.vertices.duplicate()
    rock.append_array(porch.floor.vertices)
    for side in [-1.0, 1.0]:
        var from := Vector3(0, 4.2, -8)
        var target := Vector3(side * 3.85, 0, 1.15)
        assert_true(_hits(rock, from, target + (target - from) * 0.2),
            "the lower lateral corner has rock behind it, not a view through the cut")


func test_porch_on_a_slope_and_a_giant_porch_stay_level() -> void:
    for size: Vector2 in [Vector2(6.0, 9.0), Vector2(22.0, 26.0)]:
        var case := _fitted("slope", "ramp" if size.x < 10 else "hangar", size.x, size.y)
        var site: CavePlacement = case.site
        assert_eq(site.portal_descent_deg, 0.0, "a 30° slope takes a level gallery")
        assert_gt(site.portal_axis_m, size.y / tan(deg_to_rad(30.0)), "straight until the vault is under rock")
        _check_porch(case, size.x, size.y)


func test_porch_dives_into_flat_ground_with_a_walkable_floor() -> void:
    var case := _fitted("flat", "ramp", 7.0, 6.0)
    var site: CavePlacement = case.site
    assert_eq(site.portal_descent_deg, CavePortal.MAX_DESCENT_DEG)
    assert_gt(site.mouth_depth(), 0.0, "the network lies below the plain")
    _check_porch(case, 7.0, 6.0)
    var porch := CavePortal.build_porch(case.data, site, site.openings()[0])
    var steepest := 0.0
    for index in range(0, (porch.floor.vertices as PackedVector3Array).size(), 3):
        var normal: Vector3 = porch.floor.normals[index]
        steepest = maxf(steepest, rad_to_deg(acos(clampf(normal.y, -1.0, 1.0))))
    assert_lt(steepest, 32.0, "the porch floor stays walkable")
    # Version 9: no trench, the porch opens at the back of a collapse hollow whose every face looks up.
    assert_true(porch.has("approach"), "an approach hollow")
    var faces := 0
    var downward := 0
    for surface: Dictionary in [porch.approach.wall, porch.approach.floor]:
        var vertices: PackedVector3Array = surface.vertices
        for index in range(0, vertices.size(), 3):
            faces += 1
            var normal := -(vertices[index + 1] - vertices[index]).cross(vertices[index + 2] - vertices[index]).normalized()
            downward += int(normal.y < -0.0001)
    assert_gt(faces, 500, "the hollow is a real surface")
    assert_eq(downward, 0, "no face of the hollow looks down (its rim's curtain stands upright)")
    var m := CaveApproach.model(site.profile.snapshot(site.seed), site.portal_descent_deg, site.portal_axis_m)
    var path := 0.0
    var z := 0.5
    while z < float(m.back) - float(m.run) - 1.0:
        path = maxf(path, rad_to_deg(atan(absf(CaveApproach.height(m, 0.0, z) - CaveApproach.height(m, 0.0, z - 0.5)) / 0.5)))
        z += 0.5
    assert_lt(path, 40.0, "the path down the hollow is walkable")
    var crest := CaveApproach.height(m, 0.0, float(m.back) + CaveApproach.CREST_M - 0.1)
    var cliff := crest - CaveApproach.height(m, 0.0, float(m.back) - float(m.run) - 1.0)
    assert_gt(cliff, float(m.top), "the mouth opens under a cliff taller than itself")


func test_mountain_porches_open_in_a_notch_and_the_ground_covers_its_rim() -> void:
    var cliff: CavePlacement = _fitted("cliff", "ramp", 8.0, 14.0).site
    assert_false(cliff.openings().any(func(o: Dictionary): return o.kind == "approach"), "a real cliff is its own face")
    var case := _fitted("slope", "ramp", 6.0, 9.0)
    var site: CavePlacement = case.site
    assert_true(site.openings().any(func(o: Dictionary): return o.kind == "approach"), "a 30° flank gets a notch")
    var m := CaveApproach.model(site.profile.snapshot(site.seed), site.portal_descent_deg, site.portal_axis_m)
    assert_almost_eq(float(m.tan_a), tan(deg_to_rad(30.0)), 0.15, "the notch reads the flank's grade off the fit")
    var terrace := CaveApproach.height(m, 0.0, float(m.back) - float(m.run) - 1.5, false) - CaveApproach.height(m, 0.0, 1.0, false)
    assert_lt(absf(terrace), 0.3, "a level terrace in front of the mouth")
    assert_gte((m.banks as Vector2).x, 45.0, "flanks steeper than a hollow's")
    # Ground cover: full on the rim, gone under the relief.
    var entrance := CaveEntrance.build(case.data, site, case.cave)
    var frame := site.surface_transform()
    var vertices: PackedVector3Array = entrance.wall.vertices
    var colors: PackedColorArray = entrance.wall.colors
    var full := 0
    var none := 0
    var deep := 0
    for index in range(0, vertices.size(), 5):
        var depth := CaveEntrance.ground_in_frame(case.data, frame, vertices[index].x, vertices[index].z).y - vertices[index].y
        full += int(colors[index].r > 0.95)
        none += int(colors[index].r < 0.05)
        deep += int(colors[index].r > 0.5 and depth > CaveEntrance.COVER_FLAT_M)
    assert_gt(full, 0, "the planet's ground covers the rim")
    assert_gt(none, 0, "the rock shows below it")
    assert_eq(deep, 0, "no cover deep under the relief")


func test_porch_cut_spares_the_far_side_of_a_ridge() -> void:
    var case := _fitted("ridge", "ramp", 6.0, 8.0)
    var site: CavePlacement = case.site
    var data: Relief = case.data
    var frame := site.surface_transform()
    var terrain := _terrain(data, site, 15.0, 110.0)
    var cut := CaveTerrainCut.collision_faces(terrain, Vector3.ZERO, [site])
    # Same prism direction, far beyond the ridge crest where the ground comes down to the mouth's level.
    var axes := CavePortal.porch_axes(site.portal_descent_deg)
    var far: Vector3 = (axes.forward as Vector3) * 88.0 + (axes.up as Vector3) * 3.0
    assert_true(_hits(cut, frame * (far + Vector3.UP * 20.0), frame * (far + Vector3.DOWN * 20.0)),
        "the far flank keeps its ground")


func test_doline_opens_its_chamber_to_the_sky() -> void:
    var case := _fitted("flat", "shaft", 30.0, 8.0)
    var site: CavePlacement = case.site
    var data: Relief = case.data
    var cave: Dictionary = case.cave
    var frame := site.surface_transform()
    assert_gt((cave.sky as PackedVector3Array).size(), 8, "the throat leaves an open loop at the lattice top")
    assert_gt(site.skylight_depth_m, 0.0)
    var terrain := _terrain(data, site, 30.0, 30.0)
    var cut := CaveTerrainCut.collision_faces(terrain, Vector3.ZERO, [site])
    assert_false(_hits(cut, frame * Vector3(0, 30, 0), frame * Vector3(0, -30, 0)), "open above the chamber")
    assert_true(_hits(cut, frame * Vector3(21, 30, 0), frame * Vector3(21, -30, 0)), "ground beyond the rim")
    var entrance := CaveEntrance.build(data, site, cave)
    var walls: PackedVector3Array = entrance.wall.vertices
    var origin := site.network_origin()
    for point: Vector3 in cave.sky:
        var nearest := INF
        for vertex in walls:
            nearest = minf(nearest, vertex.distance_to(point + origin))
        assert_lt(nearest, 0.0001, "funnel keeps every lattice seam vertex")
    var chamber: Dictionary = cave.graph.rooms[0]
    assert_true(CaveGenerator.contains(cave, (chamber.a as Vector3) + Vector3.UP * float(chamber.size.y) * 0.5),
        "the bell chamber lies under the throat")
    var axis: Vector2 = cave.graph.sky.center
    assert_almost_eq(Vector2(chamber.a.x, chamber.a.z), axis, Vector2.ONE * 0.000001, "throat centred on the chamber")
    assert_eq(CaveEntrance.site_error(data, site, cave), "")
    # The crust over the network grows with the oculus: never a sheet of rock over a wide hole.
    var spec := site.profile.snapshot(site.seed)
    var roof := -INF
    for point in CaveGenerator.cover_points(cave):
        roof = maxf(roof, point.y + origin.y)
    assert_lte(roof, -CavePortal.doline_crust(spec) + 0.001, "the doline keeps its crust over the whole network")
    assert_gt(CavePortal.doline_crust(spec), site.cover_m, "a 30 m doline keeps more than the plain cover")
    # Just outside the rim, under the cut ground: the collar that seals it to a terrain shown a little off.
    var rim_x := CavePortal._exit(site.openings()[0].polygon, Vector2.ZERO, Vector2.RIGHT)
    var sealed := PackedVector3Array()
    for vertex in entrance.faces:
        sealed.append(frame * vertex)
    assert_true(_hits(sealed, frame * Vector3(rim_x + 1.5, 3.0, 0.0), frame * Vector3(rim_x + 1.5, -3.0, 0.0)),
        "a collar runs under the ground beyond the rim")
    assert_false(_hits(sealed, frame * Vector3(rim_x + CaveEntrance.COLLAR_M + 1.0, 3.0, 0.0),
        frame * Vector3(rim_x + CaveEntrance.COLLAR_M + 1.0, -3.0, 0.0)), "and stops a few metres out")


func test_smooth_mouth_outlines_are_convex_and_follow_their_proportions() -> void:
    var profile := CaveWorkbench.preset(1)
    profile.entrance_noise = 0.0  # the historical smooth outline; eroded mouths: next test
    var spec := profile.snapshot(9)
    for size: Vector2 in [Vector2(4.0, 12.0), Vector2(16.0, 12.0)]:
        spec.entrance_width_m = size.x
        spec.entrance_height_m = size.y
        var arch := CavePortal.porch_arch(spec)
        assert_eq(arch.size(), CaveGenerator.RING_SEGMENTS + 1)
        var hull := Geometry2D.convex_hull(arch)
        for point in arch:
            var on_hull := false
            for index in hull.size() - 1:
                if Geometry2D.get_closest_point_to_segment(point, hull[index], hull[index + 1]).distance_to(point) < 0.001:
                    on_hull = true
            assert_true(on_hull, "every mouth point lies on the convex cut")
        var high := 0.0
        for point in arch:
            if point.y > size.y * 0.8:
                high = maxf(high, absf(point.x))
        if size.x < size.y:
            assert_lt(high, size.x * 0.4, "a slender mouth closes into a pointed fissure")
    assert_eq(CavePortal.oculus(spec), CavePortal.oculus(spec), "seeded oculus")


## The eroded outline's notches are real: the ground inside the hull but outside the outline keeps its rock.
func test_eroded_mouths_cut_exactly_their_concave_outline() -> void:
    for kind in ["ramp", "shaft"]:
        # The porch in a cliff: the prism alone cuts there (a gentler relief gets an approach around the mouth).
        var case := _fitted("cliff" if kind == "ramp" else "flat", kind, 9.0 if kind == "ramp" else 30.0, 12.0)
        var site: CavePlacement = case.site
        site.profile.entrance_noise = 0.9
        site.apply_fit(CavePortal.fit(case.data, site, case.cave))
        var opening: Dictionary = site.openings()[0]
        var outline: PackedVector2Array = opening.polygon
        assert_true(opening.has("parts"), "an eroded %s is clipped in convex parts" % kind)
        # A point of the hull that the erosion left outside the outline (a notch), and one inside the outline.
        var hull := Geometry2D.convex_hull(outline)
        var notch := Vector2.INF
        for index in hull.size() - 1:
            var probe := hull[index].lerp(hull[index + 1], 0.5).lerp(Vector2(0.0, 4.8) if kind == "ramp" else Vector2.ZERO, 0.04)
            if not Geometry2D.is_point_in_polygon(probe, outline):
                notch = probe
                break
        assert_true(notch.x < INF, "the eroded %s has a notch" % kind)
        if notch.x == INF:
            continue
        var frame: Transform3D = opening.frame
        var terrain := _terrain(case.data, site, 30.0, 40.0)
        var cut := CaveTerrainCut.collision_faces(terrain, Vector3.ZERO, [site])
        # Rays along the prism axis: through the notch the terrain answers, through the outline it does not.
        var axis: Vector2 = opening.get("axis", Vector2(-40.0, 40.0))
        var through_notch := _hits(cut, frame * Vector3(notch.x, axis.y + 30.0, notch.y),
            frame * Vector3(notch.x, axis.x - 0.5, notch.y))
        var uncut_notch := _hits(terrain, frame * Vector3(notch.x, axis.y + 30.0, notch.y),
            frame * Vector3(notch.x, axis.x - 0.5, notch.y))
        assert_eq(through_notch, uncut_notch, "%s: the notch keeps whatever ground it had" % kind)
        var centre := Vector2(0.0, 4.8) if kind == "ramp" else Vector2.ZERO
        assert_false(_hits(cut, frame * Vector3(centre.x, axis.y + 30.0, centre.y),
            frame * Vector3(centre.x, axis.x - 0.5, centre.y)), "%s: open through the outline" % kind)
        var entrance := CaveEntrance.build(case.data, site, case.cave)
        assert_eq(CaveEntrance.site_error(case.data, site, case.cave), "")


func test_unfitted_v8_sites_ask_for_a_refit_and_fits_change_the_signature() -> void:
    var case := _fitted("slope", "ramp", 6.0, 9.0)
    var site: CavePlacement = case.site
    var data: Relief = case.data
    var fitted := site.signature()
    var raw: CavePlacement = site.duplicate(true)
    raw.portal_axis_m = 0.0
    assert_string_contains(raw.validation_error(data), "recaler")
    assert_ne(raw.signature(), fitted, "cache identity follows the fitted entrance")
    assert_eq(site.validation_error(data), "")
