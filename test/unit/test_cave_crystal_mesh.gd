extends GutTest
## The corundum crystal clusters (CaveCrystalMesh): seeded, well formed, and the baked meshes the cave libraries
## use are what the generator makes today (tools/stargrot/bake_crystal_assets.tscn rebakes them).

const BAKED := "res://scenes/planet/cave/assets/crystal_corundum/corundum_cluster_%s.tres"


func test_same_seed_same_cluster_and_another_seed_another() -> void:
    for kind: String in CaveCrystalMesh.KINDS:
        var first := CaveCrystalMesh.cluster_arrays(kind, 11)
        assert_eq(first[Mesh.ARRAY_VERTEX], CaveCrystalMesh.cluster_arrays(kind, 11)[Mesh.ARRAY_VERTEX], kind)
        assert_ne(first[Mesh.ARRAY_VERTEX], CaveCrystalMesh.cluster_arrays(kind, 12)[Mesh.ARRAY_VERTEX], kind)


func test_facets_are_flat_outward_and_rooted_on_the_support() -> void:
    for kind: String in CaveCrystalMesh.KINDS:
        var arrays := CaveCrystalMesh.cluster_arrays(kind, 7)
        var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
        var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
        var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
        assert_eq(vertices.size() % 3, 0, "a triangle list")
        assert_eq(normals.size(), vertices.size())
        assert_eq(colors.size(), vertices.size())
        var lowest := INF
        var highest := -INF
        for index in range(0, vertices.size(), 3):
            var a := vertices[index]
            var b := vertices[index + 1]
            var c := vertices[index + 2]
            assert_almost_eq(normals[index].length(), 1.0, 1e-4, "unit normals")
            assert_eq(normals[index], normals[index + 2], "flat-shaded facet")
            # Godot's front faces wind clockwise: (c - a) x (b - a) is the facet's outward normal.
            assert_gt((c - a).cross(b - a).dot(normals[index]), 0.0, "winding matches the normal")
            for corner in 3:
                lowest = minf(lowest, vertices[index + corner].y)
                highest = maxf(highest, vertices[index + corner].y)
                assert_between(colors[index + corner].r, 0.0, 1.0, "COLOR.r = height along the crystal")
        assert_lt(lowest, 0.0, "%s: roots buried under the support" % kind)
        assert_gt(lowest, -CaveCrystalMesh.BURY_M / 0.3 - 1e-4, "%s: never deeper than the root ring" % kind)
        assert_gt(highest, float(CaveCrystalMesh.KINDS[kind].length[0]) * 0.5, "%s: crystals stand out" % kind)


func test_baked_meshes_are_the_generator_s() -> void:
    for kind: String in CaveMineral.CRYSTAL_SEEDS:
        var baked: ArrayMesh = load(BAKED % kind)
        assert_not_null(baked, "baked %s cluster" % kind)
        var fresh := CaveCrystalMesh.cluster(kind, CaveMineral.CRYSTAL_SEEDS[kind])
        assert_eq(baked.surface_get_array_len(0), fresh.surface_get_array_len(0),
            "%s is stale: run tools/stargrot/bake_crystal_assets.tscn" % kind)
        assert_true(baked.get_aabb().is_equal_approx(fresh.get_aabb()), "%s bounds" % kind)


func test_rock_libraries_grow_crystals_and_stay_valid() -> void:
    for open_mouth in [false, true]:
        var library := CaveAssetLibrary.default_for("rock", open_mouth)
        assert_eq(library.validation_error(), "", library.library_id)
        assert_not_null(library.mineral_style, "%s shows its rock" % library.library_id)
        var supports := []
        for rule in library.decorations:
            if rule.mineral_crystal:
                supports.append(rule.support)
                assert_null(rule.collision_shape, "crystals are visual only (the server has no mineral)")
        assert_eq(supports, ["floor", "wall", "ceiling"], library.library_id)
    assert_null(CaveAssetLibrary.default_for("ice").mineral_style, "ice keeps its authored look")
