extends GutTest
## The dust cloud of a fallen layer (MineDustCloud): along the gallery from the face, blinding, then clearing.


func test_the_cloud_follows_the_gallery_back_from_the_face() -> void:
    var plan := MineLayout.generate(77, {}, MineLayout.STYLE_CHAOTIC)
    var gallery: Dictionary = plan.galleries[0]
    var path := MineDustCloud.gallery_path(plan, 0, 30.0, 40.0, 2.0)
    assert_almost_eq(path[0], MineLayout.point_at(gallery, 30.0) + Vector3.UP * 2.0, Vector3.ONE * 1.0e-4,
        "starts at the face, raised")
    assert_almost_eq(path[path.size() - 1], MineLayout.point_at(gallery, 0.0) + Vector3.UP * 2.0, Vector3.ONE * 1.0e-4,
        "never past the station")
    var far := MineDustCloud.gallery_path(plan, 0, 200.0, 40.0, 0.0)
    assert_almost_eq(far[far.size() - 1], MineLayout.point_at(gallery, 160.0), Vector3.ONE * 1.0e-4, "40 m at most")
    assert_true(far.size() - 1 <= MineDustCloud.MAX_SEGMENTS)
    var long := MineDustCloud.gallery_path(plan, 0, 500.0, 400.0, 0.0)
    assert_eq(long.size() - 1, MineDustCloud.MAX_SEGMENTS, "a long reach fits the shader's segments")


func test_blinding_then_clearing_in_forty_seconds() -> void:
    var peak := MineDustCloud.density_at(MineDustCloud.RISE_S, 40.0, 0.8)
    assert_gt(peak * 0.8, 3.5, "at its thickest, nothing is seen past 0.8 m")
    assert_lt(MineDustCloud.density_at(0.2, 40.0, 0.8), peak, "it thickens first")
    var last := peak
    for second in range(2, 40):
        var density := MineDustCloud.density_at(float(second), 40.0, 0.8)
        assert_true(density < last, "thinner every second (%d s)" % second)
        last = density
    assert_eq(MineDustCloud.density_at(40.0, 40.0, 0.8), 0.0, "clear at 40 s")
    # Half way, still thick: a few metres of sight.
    assert_lt(MineDustCloud.HIDDEN_DEPTH / MineDustCloud.density_at(20.0, 40.0, 0.8), 5.0)


func test_the_dust_rushes_then_slows() -> void:
    assert_eq(MineDustCloud.front_at(0.0, 6.0, 40.0), 0.0)
    assert_almost_eq(MineDustCloud.front_at(6.0, 6.0, 40.0), 36.0, 0.01, "nine tenths in spread_s")
    assert_lt(MineDustCloud.front_at(100.0, 6.0, 40.0), 40.0 + 1.0e-6)


func test_the_cloud_goes_once_clear() -> void:
    var cloud := MineDustCloud.new()
    cloud.clear_s = 0.05
    add_child_autofree(cloud)
    cloud.setup(PackedVector3Array([Vector3(0, 2, 0), Vector3(0, 2, 5)]), 4.0, Color.GRAY)
    assert_not_null(cloud.mesh, "a box round the path")
    assert_true(cloud.mesh.get_aabb().has_point(Vector3(0, 2, 2.5) - cloud.position))
    await wait_seconds(0.2)
    assert_false(is_instance_valid(cloud) and cloud.is_inside_tree() and not cloud.is_queued_for_deletion(), "freed")
