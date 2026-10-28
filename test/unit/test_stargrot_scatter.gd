extends GutTest


func before_all() -> void:
    CaveNetwork.warm()


func test_geological_family_uses_real_art_and_preserves_custom_compatible_library() -> void:
    var profile := CaveProfile.new()
    CavePopulation.apply_family(profile, "basalt")
    assert_eq(profile.asset_library.library_id, "rock_sculpted_open_v1")
    var custom: CaveAssetLibrary = profile.asset_library.duplicate()
    custom.library_id = "my_rock_library"
    profile.asset_library = custom
    CavePopulation.apply_family(profile, "rock")
    assert_true(profile.asset_library == custom)
    CavePopulation.apply_family(profile, "ice")
    assert_eq(profile.asset_library.surface_family, "ice")


func test_redressing_preserves_geometry_fit_and_other_planets() -> void:
    var first: CavePlacement = load("res://levels/stargrot/initial_cave.tres").duplicate(true)
    first.placement_id = "one"
    var second: CavePlacement = first.duplicate(true)
    second.placement_id = "two"
    second.planet_name = "other_planet"
    var collection := CaveSiteCollection.new()
    collection.sites = [first, second]
    collection.selected_id = first.placement_id
    var library := CaveAssetLibrary.default_for("rock", true)
    var before := first.signature()
    var next := collection.with_library(first.planet_name, library, false)
    assert_true(next.sites[0].profile.asset_library == library)
    assert_eq(next.sites[0].signature(), before, "dressing does not alter geometry or terrain cut identity")
    assert_eq(next.sites[0].cave_transform(), first.cave_transform())
    assert_true(next.sites[1] == second, "other planet remains shared and unchanged")
    assert_false(first.profile.asset_library == library, "source collection kept for undo")


func test_entrance_noise_is_opt_in_seeded_and_carves_concave_mouths() -> void:
    var profile := CaveWorkbench.preset(1)
    profile.entrance_noise = 0.0
    var legacy := profile.snapshot(42)
    assert_false(legacy.has("entrance_noise"), "zero preserves historical snapshots and hashes")
    var arch := CavePortal.porch_arch(legacy)
    assert_eq(arch.size(), CaveGenerator.RING_SEGMENTS + 1, "smooth mouths keep the ring contract")
    profile.entrance_noise = 0.8
    var changed := profile.snapshot(42)
    assert_eq(CaveGenerator.validation_error(changed), "")
    assert_eq(CavePortal.porch_arch(changed), CavePortal.porch_arch(changed), "seeded mouth")
    assert_eq(CavePortal.oculus(changed), CavePortal.oculus(changed), "seeded rim")
    for eroded: PackedVector2Array in [CavePortal.porch_arch(changed), CavePortal.oculus(changed)]:
        assert_false(Geometry2D.triangulate_polygon(eroded).is_empty(), "a simple outline, no self-crossing")
        var hull := Geometry2D.convex_hull(eroded)
        assert_gt(absf(CavePortal._area(hull)) - absf(CavePortal._area(eroded)), 0.5, "erosion bites into the outline")
        var tiled := 0.0
        for part in CavePortal.convex_parts(eroded):
            assert_true(_convex(part), "every clipping part is convex")
            tiled += absf(CavePortal._area(part))
        assert_almost_eq(tiled, absf(CavePortal._area(eroded)), 0.001 * absf(CavePortal._area(eroded)),
            "the convex parts tile the eroded outline exactly")
    var eroded_arch := CavePortal.porch_arch(changed)
    assert_ne(eroded_arch, arch, "noise changes the real mouth contour")
    assert_eq(eroded_arch[0], arch[0], "the sill keeps its corners")
    assert_eq(eroded_arch[-1], arch[-1])
    assert_eq((eroded_arch.size() - 1) % CaveGenerator.RING_SEGMENTS, 0, "finer outline, still on the ring's segments")
    profile.entrance_noise = 2
    assert_false(CaveGenerator.validation_error(profile.snapshot(42)).is_empty())


func test_scatter_is_seeded_bounded_and_attached_to_the_actual_volume() -> void:
    var library := CaveAssetLibrary.default_for("rock")
    var profile := CaveWorkbench.preset(1, "rock", library)
    profile.chamber_count = 5
    profile.level_count = 1
    profile.depth_m = 0
    profile.chamber_width_m = 40
    profile.chamber_height_m = 18
    profile.network_style = "ramiform"
    var data := CaveGenerator.build(profile.snapshot(7654321))
    assert_eq(str(data.error), "")
    var nonempty := 0
    for rule in library.decorations:
        var first := CavePreviewBuilder.decoration_transforms(data, rule, 20)
        assert_eq(first, CavePreviewBuilder.decoration_transforms(data, rule, 20), "same seed, same placements")
        assert_lte(first.size(), 20)
        if not first.is_empty():
            nonempty += 1
        for transform in first:
            var inside: Vector3 = transform.origin + transform.basis.y.normalized() * 0.2
            assert_gt(float(data.sampler.call("Sample", inside)), -0.4, "asset grows into cave air")
    assert_gte(nonempty, 4, "multiple asset types fit without forcing every type into every cave")
    var request := CavePreviewBuilder.decoration_request(library)
    assert_true(_plain(request), "worker requests contain no nodes or resources")
    var prepared := CavePreviewBuilder.prepare_decorations(data, request)
    data["decoration_plan"] = prepared
    data.sampler = null  # Assembly must consume the prepared plan, not sample geometry again.
    var preview := CavePreviewBuilder.instantiate(data, library, true, false)
    assert_gt(preview.find_children("Decor_*", "MultiMeshInstance3D", false, false).size(), 0)
    preview.free()
    var different: CaveAssetLibrary = library.duplicate()
    different.instance_budget += 1
    assert_ne(request.signature, CavePreviewBuilder.decoration_request(different).signature,
        "a changed library budget invalidates its dressing plan")


## Every turn goes the same way (collinear points allowed).
static func _convex(polygon: PackedVector2Array) -> bool:
    var sign := 0.0
    for index in polygon.size():
        var a := polygon[index]
        var b := polygon[(index + 1) % polygon.size()]
        var c := polygon[(index + 2) % polygon.size()]
        var turn := (b - a).cross(c - b)
        if absf(turn) < 1.0e-9:
            continue
        if sign != 0.0 and signf(turn) != sign:
            return false
        sign = signf(turn)
    return true


func _plain(value: Variant) -> bool:
    if value is Object:
        return false
    if value is Dictionary:
        for child in value.values():
            if not _plain(child):
                return false
    if value is Array:
        for child in value:
            if not _plain(child):
                return false
    return true
