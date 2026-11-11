extends GutTest
## The truck elevator: the second VehicleLift model (VehicleLiftModel), a concrete tower stacked from the top with
## 10 m sections, its platform in front, a call kiosk at each stop; and how a village mine stands it in its shaft, the
## platform's front at the stations' mouth.

const LIFT := "res://scenes/_universe/structures/industrial/truck_elevator/truck_elevator.tscn"
const MODEL := "res://scenes/_universe/structures/industrial/truck_elevator/truck_elevator_model.tres"


func _lift(depth: float, stops: Array) -> VehicleLift:
    var lift: VehicleLift = load(LIFT).instantiate()
    lift.descent_depth = depth
    lift.stop_depths = PackedFloat32Array(stops)
    add_child_autofree(lift)
    return lift


func test_the_tower_reaches_the_base_however_deep() -> void:
    var model: VehicleLiftModel = load(MODEL)
    for depth: float in [20.77, 40.77, 247.9, 600.0, 997.9]:
        var count := model.segment_count(depth)
        var top := -model.segment_top_m
        assert_almost_eq(model.segment_y(0), top, 1.0e-4, "the first section hangs from the top piece")
        # The sections reach the base's top (segment_bottom_m above the foot), the last one sinking into it.
        var bottom := model.segment_y(count - 1) - model.segment_height_m if count > 0 else top
        assert_true(bottom <= -(depth - model.segment_bottom_m) + 1.0e-4, "%.1f m: no gap above the base" % depth)
        assert_true(bottom > -(depth - model.segment_bottom_m) - model.segment_height_m, "%.1f m: not one too many" % depth)


func test_parts_the_model_has_not_are_not_built() -> void:
    var lift := _lift(60.0, [30.0])
    for absent in ["Base", "Rail Head", "Dynamic Bridges"]:
        assert_null(lift.get_node_or_null(absent), absent + ": not in this model")
    assert_not_null(lift.get_node_or_null("Upper Landing"))
    var lower := lift.get_node_or_null("Lower Landing") as Node3D
    assert_not_null(lower)
    assert_almost_eq(lower.position, Vector3(0, -60.0, 0), Vector3.ONE * 1.0e-4, "the foot's deck, descent_depth down")
    assert_eq(lift.get_node("Rail Segments/Visuals").get_child_count(), 4, "60 m: four 10 m sections")
    var tower := (lift.get_node("Rail Segments/Collider") as CollisionShape3D).shape as BoxShape3D
    assert_almost_eq(tower.size.x, 6.93, 1.0e-3, "the tower's width")


func test_each_stop_has_its_call_kiosk() -> void:
    var lift := _lift(120.0, [40.0, 90.0])
    for index in 2:
        var landing := lift.get_node_or_null("StopLanding%d" % index) as LiftLanding
        assert_not_null(landing, "stop %d: a landing" % index)
        if landing == null:
            continue
        assert_eq(landing.stop_index, index)
        assert_almost_eq(landing.position.y, -float(lift.stop_depths[index]), 1.0e-4)
        assert_null(landing.get_node_or_null("Bridge"), "no bridge: the platform reaches the station")
        assert_not_null(landing.get_node_or_null("%Beacon Left"), "beacons for LiftLanding")
        assert_not_null(landing.landing_interface, "a screen for LiftLanding")


func test_the_mine_stands_the_elevator_facing_its_stations() -> void:
    var site: MineSite = load("res://scenes/_universe/structures/industrial/mines/shaft/mine_site.tscn").instantiate()
    var plan := MineLayout.generate(77, {}, MineLayout.STYLE_STRAIGHT)
    var radius := float(plan.settings.shaft_radius_m)
    var flat := -float(plan.settings.shaft_flat_m)
    var origin := site.lift_origin()
    var basis := MineSite.lift_basis()
    assert_lt((basis * Vector3.BACK).z, -0.99, "the platform goes towards -Z, the stations")
    # The tower's back in the +Z wall.
    var back := origin + basis * Vector3(0, 0, -MineSite.LIFT_TOWER_DEPTH_M)
    assert_between(back.z, radius, radius + 2.0, "the tower's back in the +Z wall")
    # The platform's front just short of the shaft's flat side, which every station's floor meets.
    var front := origin + basis * Vector3(0, 0, MineSite.LIFT_PLATFORM_FRONT_M)
    assert_between(front.z - flat, 0.0, 0.1, "the platform's front at the shaft's flat side")
    var dug := MineLayout.dug(plan, {}, {})
    for level: Dictionary in plan.levels:
        var station: Vector3 = level.station
        var mouth := station.z + float(plan.settings.station_length_m) * 0.5
        assert_gt(mouth, flat, "level %d: the station reaches past the flat side" % level.index)
        for x: float in [-4.6, 0.0, 4.6]:
            var past := Vector3(x, float(level.y) + 0.5, flat - 0.5)
            assert_true(MineLayout.contains(plan, dug, past), "level %d: the station's floor past the platform" % level.index)
    # Riding down, the deck's corners (9 m wide) stay clear of the round wall's relief.
    var wall := radius - float(plan.settings.shaft_roughness_m)
    for x: float in [-4.57, 4.43]:
        for along: float in [0.0, MineSite.LIFT_PLATFORM_FRONT_M]:
            var corner := origin + basis * Vector3(x, 0, along)
            assert_lt(Vector2(corner.x, corner.z).length(), wall - 0.3, "deck corner %.1f/%.1f clear" % [x, along])
    site.free()


func test_the_shaft_has_a_flat_side_under_its_collar() -> void:
    if not MineMesher.warm():
        pending("native mesher not built")
        return
    var plan := MineLayout.generate(77, {}, MineLayout.STYLE_STRAIGHT)
    var mesher := MineMesher.configure(MineLayout.graph(plan, MineLayout.dug(plan, {}, {})))
    var flat := -float(plan.settings.shaft_flat_m)
    # Half way between the first two levels: no station there.
    var y := (float(plan.levels[0].y) + float(plan.levels[1].y)) * 0.5
    assert_gt(float(mesher.call("Sample", Vector3(0, y, flat + 0.3))), 0.0, "air just inside the flat side")
    assert_lt(float(mesher.call("Sample", Vector3(0, y, flat - 0.3))), 0.0, "rock just past it, between levels")
    assert_gt(float(mesher.call("Sample", Vector3(0, -4.0, flat - 1.5))), 0.0, "round under the collar")
