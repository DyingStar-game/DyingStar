extends GutTest
## Data-free regressions; discovered by the existing DyingStar GUT suite.

const Fixture := preload("res://test/unit/stargrot_fixture.gd")


func before_all() -> void:
    CaveNetwork.warm()


func test_interior_includes_chamber_air_but_excludes_solid_rock() -> void:
    var placement := Fixture.placement()
    var data := Fixture.data(placement)
    var cave := Fixture.fit(placement, data)
    data.stargrot_plans = [{"placement": placement, "cave": cave}]
    for room: Dictionary in cave.graph.rooms:
        var height := -6.0
        while height < float(room.size.y) and float(cave.sampler.call("Sample", room.a + Vector3.UP * height)) <= 0.5:
            height += 0.25
        var air: Vector3 = room.a + Vector3.UP * (height + 0.2)
        assert_true(CavePlanetRegistry.contains(data, placement.cave_transform() * air), "open %s" % room.archetype)
    var rock: Vector3 = (cave.graph.bounds as AABB).end + Vector3.ONE * 20.0
    assert_false(CavePlanetRegistry.contains(data, placement.cave_transform() * rock))


func test_missing_or_non_finite_inputs_are_rejected_without_runtime_errors() -> void:
    var profile := Fixture.profile()
    for key in ["seed", "version", "chambers", "length_m", "entrance_type", "exit_open"]:
        var spec := profile.snapshot(42)
        spec.erase(key)
        assert_false(CaveGenerator.validation_error(spec).is_empty(), key)
    var spec := profile.snapshot(42)
    spec.chambers = NAN
    assert_false(CaveGenerator.validation_error(spec).is_empty())
    spec.chambers = 1.5
    assert_false(CaveGenerator.validation_error(spec).is_empty())
    for version in [1, 7, 10]:
        spec = profile.snapshot(42)
        spec.version = version
        assert_false(CaveGenerator.validation_error(spec).is_empty(), "version %d is not supported" % version)


func test_entrance_variants_are_deterministic_and_non_degenerate() -> void:
    var profile := Fixture.profile()
    profile.chamber_width_m = 80.0
    profile.chamber_height_m = 35.0
    profile.roughness = 1.0
    profile.exit_open = true
    for kind in ["ramp", "shaft", "hangar"]:
        profile.entrance_type = kind
        profile.entrance_width_m = 50.0 if kind == "hangar" else (30.0 if kind == "shaft" else 4.0)
        profile.entrance_height_m = 30.0 if kind == "hangar" else 5.0
        for cave_seed in [1, 104729]:
            var spec := profile.snapshot(cave_seed)
            var cave := CaveGenerator.build(spec)
            assert_eq(cave.error, "", "%s %d" % [kind, cave_seed])
            if not cave.error.is_empty():
                continue
            assert_eq(cave.faces, CaveGenerator.build(spec).faces, "same seed / " + kind)
            var non_degenerate := true
            for index in range(0, cave.faces.size(), 3):
                var a: Vector3 = cave.faces[index]
                var b: Vector3 = cave.faces[index + 1]
                var c: Vector3 = cave.faces[index + 2]
                # The mesher's sliver floor: smaller triangles are dropped, larger slivers (0.05 mm edges) are valid.
                if (b - a).cross(c - a).length_squared() < 1.0e-18:
                    non_degenerate = false
                    break
            assert_true(non_degenerate, "geometry / " + kind)
            var placement := Fixture.placement(profile, cave_seed)
            assert_eq(placement.openings().size(), 2, "mouth and exit / " + kind)


func test_cut_preserves_native_uv2_skirt_offsets_tangents_and_road_mapping() -> void:
    var placement := Fixture.placement()
    var frame := placement.surface_transform()
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    var vertices := PackedVector3Array()
    var uv2s := PackedVector2Array()
    var offsets := PackedFloat32Array()
    var rocks := PackedFloat32Array()
    for point in [Vector3(-200, 0, -200), Vector3(200, 0, -200), Vector3(0, 0, 200)]:
        var p: Vector3 = frame.basis * point
        vertices.append(p)
        uv2s.append(Vector2(p.x * 0.1, p.z * 0.1))
        offsets.append_array(PackedFloat32Array([p.x * 0.01, p.y * 0.02, p.z * 0.03]))
        rocks.append_array(PackedFloat32Array([p.x * 0.001, p.y * 0.002, p.z * 0.003, 2.0]))
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([frame.basis.y, frame.basis.y, frame.basis.y])
    arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.ONE])
    arrays[Mesh.ARRAY_TEX_UV2] = uv2s
    arrays[Mesh.ARRAY_CUSTOM0] = offsets
    arrays[Mesh.ARRAY_CUSTOM1] = rocks
    arrays[Mesh.ARRAY_TANGENT] = PlanetChunk._compute_tangents(vertices, arrays[Mesh.ARRAY_NORMAL],
        arrays[Mesh.ARRAY_TEX_UV], PackedInt32Array([0, 1, 2]))
    var source := ArrayMesh.new()
    var flags := Mesh.ARRAY_CUSTOM_RGB_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
    flags |= Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT
    source.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
    source.set_meta("road_surfaces", PackedInt32Array([0]))
    source.set_meta("roads_mesh", ArrayMesh.new())
    var output := CaveTerrainCut.mesh(source, frame.origin, [placement])
    assert_eq(source.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(), 3, "source stays immutable")
    assert_false(output.has_meta("roads_mesh"), "stale road geometry removed")
    assert_eq(output.get_meta("road_surfaces"), PackedInt32Array([0]))
    var result := output.surface_get_arrays(0)
    assert_eq(result[Mesh.ARRAY_CUSTOM0].size(), result[Mesh.ARRAY_VERTEX].size() * 3)
    assert_eq(result[Mesh.ARRAY_CUSTOM1].size(), result[Mesh.ARRAY_VERTEX].size() * 4)
    assert_eq((output.surface_get_format(0) >> Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) & 7, Mesh.ARRAY_CUSTOM_RGBA_FLOAT)
    assert_eq(result[Mesh.ARRAY_TANGENT].size(), result[Mesh.ARRAY_VERTEX].size() * 4)
    var preserved := true
    for index in result[Mesh.ARRAY_VERTEX].size():
        var p: Vector3 = result[Mesh.ARRAY_VERTEX][index]
        var custom := Vector3(result[Mesh.ARRAY_CUSTOM0][index * 3],
            result[Mesh.ARRAY_CUSTOM0][index * 3 + 1], result[Mesh.ARRAY_CUSTOM0][index * 3 + 2])
        var rock := Vector3(result[Mesh.ARRAY_CUSTOM1][index * 4],
            result[Mesh.ARRAY_CUSTOM1][index * 4 + 1], result[Mesh.ARRAY_CUSTOM1][index * 4 + 2])
        if rock.distance_to(Vector3(p.x * 0.001, p.y * 0.002, p.z * 0.003)) > 0.0001 \
                or absf(result[Mesh.ARRAY_CUSTOM1][index * 4 + 3] - 2.0) > 0.0001:
            preserved = false
        if custom.distance_to(Vector3(p.x * 0.01, p.y * 0.02, p.z * 0.03)) > 0.0001:
            preserved = false
        if result[Mesh.ARRAY_TEX_UV2][index].distance_to(Vector2(p.x * 0.1, p.z * 0.1)) > 0.001:
            preserved = false
    assert_true(preserved, "interpolated native shader attributes")


func test_duplicate_identities_fail_before_generating_any_geometry() -> void:
    var placement := Fixture.placement()
    var data := Fixture.data(placement)
    data.cave_placements = [placement, placement.duplicate(true)]
    assert_false(CavePlanetRegistry.prepare(data).is_empty())
    assert_true(data.stargrot_plans.is_empty())


func test_saved_placements_and_decoration_rules_reject_non_finite_values() -> void:
    var placement := Fixture.placement()
    placement.longitude_deg = NAN
    assert_false(placement.definition_error().is_empty())
    placement = Fixture.placement()
    placement.profile.asset_library = placement.profile.asset_library.duplicate(true)
    placement.profile.asset_library.decorations[0].spacing_m = NAN
    assert_false(placement.definition_error().is_empty())
    placement = Fixture.placement()
    placement.profile.asset_library = placement.profile.asset_library.duplicate(true)
    placement.profile.asset_library.decorations[0].max_instances = -1
    assert_false(placement.definition_error().is_empty())


func test_standard_planet_uses_the_shipped_catalog_without_inline_demo_sites() -> void:
    var properties := SystemScenes.root_properties("res://scenes/systems/tarsis/tarsis_3.tscn")
    var data := properties.planet_data as PlanetData
    assert_true(data.cave_placements.is_empty(), "authored content stays in its runtime catalog")
    assert_true(data.cave_catalog != null and data.cave_catalog.sites.size() == 200,
        "normal Tarsis III scene supplies the user's 200 cave definitions")


func test_legacy_coordinate_migration_preserves_world_position_and_is_idempotent() -> void:
    var site := Fixture.placement()
    site.format_version = 1
    site.longitude_deg = -39.58
    site.latitude_deg = 24.82
    var legacy := site.surface_transform()
    var lat := deg_to_rad(site.latitude_deg)
    var lon := deg_to_rad(site.longitude_deg)
    assert_lt(site.surface_direction().distance_to(Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))), 0.000001)
    site.migrate_coordinates()
    assert_eq(site.format_version, 2)
    assert_eq(site.longitude_deg, 39.58)
    assert_lt(site.surface_transform().origin.distance_to(legacy.origin), 0.000001)
    assert_eq(site.surface_transform().basis, legacy.basis)
    var signature := site.signature()
    site.migrate_coordinates()
    assert_eq(site.signature(), signature)
    site.format_version = 3
    assert_false(site.definition_error().is_empty())
