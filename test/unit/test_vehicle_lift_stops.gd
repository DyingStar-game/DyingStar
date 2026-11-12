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


## A part in VehicleLift.DEPARTURE_GATE_GROUP that holds the lift (stands for the truck elevator's ramp, folding).
class Gate:
    extends Node
    var holding := true

    func holds_departure() -> bool:
        return holding


func test_a_called_lift_waits_for_its_gates() -> void:
    var lift := _lift(100.0, [])
    var gate := Gate.new()
    gate.add_to_group(VehicleLift.DEPARTURE_GATE_GROUP)
    lift.add_child(gate)
    assert_true(lift._departure_held(), "the ramp is still folding")
    gate.holding = false
    assert_false(lift._departure_held(), "folded: off it goes")
    var stranger := Gate.new()
    stranger.add_to_group(VehicleLift.DEPARTURE_GATE_GROUP)
    add_child_autofree(stranger)
    assert_false(lift._departure_held(), "another lift's ramp does not hold this one")


func test_a_blocked_gate_is_heard_by_clients() -> void:
    # The server's ramp says something stands in its way; each client's ramp waits on that word.
    var lift := _lift(100.0, [])
    assert_false(lift.departure_blocked())
    lift.apply_prop_data({"departure_blocked": true})
    assert_true(lift.departure_blocked(), "replicated: the client's ramp waits")
    lift.apply_prop_data({"platform_progress_ratio": 0.0})
    assert_true(lift.departure_blocked(), "an update without it keeps it")
    lift.set_departure_blocked(false)
    assert_false(lift.departure_blocked(), "clear: it folds")





func test_the_deck_is_raised_at_the_foot_and_the_stops_alike_never_at_the_top() -> void:
    # The truck elevator's deck rests on its pit's slab at the foot, 36 cm up; the levels' floors are at their
    # height: one raise for the stops, one for the foot (playtest 2026-11-12), each taken up on the way.
    var ramp := VehicleLift.STOP_RAISE_RAMP_M
    assert_eq(VehicleLift.raise_at(0.0, 100.0, 0.1, 0.36), 0.0, "the upper landing: untouched")
    assert_almost_eq(VehicleLift.raise_at(40.0, 100.0, 0.1, 0.36), 0.1, 1.0e-6, "a stop")
    assert_almost_eq(VehicleLift.raise_at(ramp * 0.5, 100.0, 0.1, 0.36), 0.05, 1.0e-6, "taken up leaving the top")
    assert_almost_eq(VehicleLift.raise_at(100.0, 100.0, 0.1, 0.36), 0.36, 1.0e-6, "the foot")
    assert_almost_eq(VehicleLift.raise_at(100.0 - ramp * 0.5, 100.0, 0.1, 0.36), 0.23, 1.0e-6, "taken up coming down")
    assert_eq(VehicleLift.raise_at(40.0, 100.0, 0.0, 0.0), 0.0, "a lift without them: the depth")


func test_the_truck_elevator_raises_its_deck_at_the_foot_only() -> void:
    var model := load("res://scenes/_universe/structures/industrial/truck_elevator/truck_elevator_model.tres") as VehicleLiftModel
    assert_eq(model.stop_raise_m, 0.0, "level with the stations' floors")
    assert_gt(model.foot_raise_m, 0.0, "on the pit's slab")
    assert_eq(model.platform_system_offset, Vector3.ZERO, "level with the road at the top")
    var first := load("res://scenes/_universe/structures/industrial/vehicle_lift/vehicle_lift_model_a.tres") as VehicleLiftModel
    assert_eq(first.foot_raise_m, 0.0, "the first lift is left as it was")


func test_the_ramp_reaches_down_to_a_lower_floor() -> void:
    assert_almost_eq(TruckElevatorRamp.laid_angle(0.0, 5.0), deg_to_rad(5.0), 1.0e-6, "level: its own angle")
    var tip := TruckElevatorRamp.REACH_M * sin(TruckElevatorRamp.laid_angle(0.36, 5.0))
    assert_almost_eq(tip, 0.36 + TruckElevatorRamp.TIP_DIP_M, 1.0e-4, "the foot: down onto the slab")
