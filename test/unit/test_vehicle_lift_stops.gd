extends GutTest
## A vehicle lift with intermediate stops (VehicleLift.stop_depths), as a village mine's shaft has one per level:
## a landing at each stop, the platform's down / up buttons going to the next stop.

const LIFT := "res://scenes/_universe/structures/industrial/vehicle_lift/vehicle_lift.tscn"


func _lift(depth: float, stops: Array) -> VehicleLift:
    var lift: VehicleLift = load(LIFT).instantiate()
    add_child_autofree(lift)
    lift.descent_depth = depth
    lift.stop_depths = PackedFloat32Array(stops)
    return lift


func _at(lift: VehicleLift, depth: float) -> void:
    lift.platform_progress_ratio = depth / lift.descent_depth * 100.0


func test_a_landing_at_each_stop() -> void:
    var lift := _lift(300.0, [40.0, 110.0, 190.0])
    lift.guide_z_offset = 2.0
    for index in 3:
        var landing := lift.get_node_or_null("StopLanding%d" % index) as LiftLanding
        assert_not_null(landing, "stop %d has its landing" % index)
        if landing != null:
            assert_eq(landing.stop_index, index)
            assert_false(landing.is_upper, "calls the platform to its stop, not up")
            assert_almost_eq(landing.position, Vector3(0, -float(lift.stop_depths[index]), 2.0), Vector3.ONE * 1.0e-4)


func test_buttons_go_to_the_next_stop() -> void:
    var lift := _lift(300.0, [110.0, 40.0, 190.0])
    _at(lift, 0.0)
    assert_almost_eq(lift.next_stop_ratio(true), 40.0 / 3.0, 1.0e-3, "down from the top: first stop")
    _at(lift, 110.0)
    assert_almost_eq(lift.next_stop_ratio(true), 190.0 / 3.0, 1.0e-3, "down: the next one")
    assert_almost_eq(lift.next_stop_ratio(false), 40.0 / 3.0, 1.0e-3, "up: the one above")
    _at(lift, 190.0)
    assert_almost_eq(lift.next_stop_ratio(true), 100.0, 1.0e-3, "down from the last stop: the bottom")
    _at(lift, 40.0)
    assert_almost_eq(lift.next_stop_ratio(false), 0.0, 1.0e-3, "up from the first stop: the top")


func test_no_stops_is_a_plain_lift() -> void:
    var lift := _lift(60.0, [])
    _at(lift, 0.0)
    assert_eq(lift.next_stop_ratio(true), 100.0)
    _at(lift, 60.0)
    assert_eq(lift.next_stop_ratio(false), 0.0)


func test_a_mine_stops_at_every_level_but_the_bottom() -> void:
    var plan := MineLayout.generate(42)
    var stops := MineSite.lift_stops(plan)
    assert_eq(stops.size(), plan.levels.size() - 1, "the bottom level is the lower landing")
    for index in stops.size():
        assert_almost_eq(float(stops[index]), -float(plan.levels[index].y), 1.0e-3)
