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


func test_the_station_is_vaulted_with_room_for_a_truck_at_the_platform() -> void:
    if not MineMesher.warm():
        pending("native mesher not built")
        return
    var plan := MineLayout.generate(77, {}, MineLayout.STYLE_STRAIGHT)
    var mesher := MineMesher.configure(MineLayout.graph(plan, MineLayout.dug(plan, {}, {})))
    var level: Dictionary = plan.levels[0]
    var station: Vector3 = level.station
    var floor_y := float(level.y)
    var flat := -float(plan.settings.shaft_flat_m)
    for x: float in [-4.5, 0.0, 4.5]:
        var headroom := Vector3(x, floor_y + 4.8, flat - 0.5)
        assert_gt(float(mesher.call("Sample", headroom)), 0.0, "room for a truck at the platform (x %.1f)" % x)
    var height := float(plan.settings.station_height_m)
    assert_gt(float(mesher.call("Sample", station + Vector3(0, height - 1.5, 0))), 0.0, "air under the vault's top")
    var corner := station + Vector3(float(plan.settings.station_width_m) * 0.5 - 2.0, height - 2.0, 0)
    assert_lt(float(mesher.call("Sample", corner)), 0.0, "a rounded vault: rock in its upper corners")


func test_a_truck_drives_level_from_the_platform_into_the_galleries() -> void:
    # The station and the galleries leaving it were blended one by one: their floors, at one height, each took the
    # smooth union's share of air, and the floor sank 60 cm under the galleries' start, 4 m past the lift -- a step a
    # truck could not climb (playtest 2026-11-12). Joined as one feature, the floor stays level up to the galleries.
    if not MineMesher.warm():
        pending("native mesher not built")
        return
    for seed: int in [11, 4242, 98765]:
        var plan := MineLayout.generate(seed)
        var mesher := MineMesher.configure(MineLayout.graph(plan, MineLayout.dug(plan, {}, {})))
        var level: Dictionary = plan.levels[0]
        var floor_y := float(level.y)
        var hub: Vector3 = level.hub
        var z := -float(plan.settings.shaft_flat_m) - 1.0
        while z >= hub.z:  # past the hub the galleries take their grade
            for x: float in [-3.0, 0.0, 3.0]:
                var ground := _floor_at(mesher, x, z, floor_y)
                assert_almost_eq(ground, floor_y, 0.1, "seed %d: level floor at x %.0f z %.1f" % [seed, x, z])
            z -= 1.0


## The floor under (x, z) near [param near_y]: the highest rock going down from 3 m above it.
func _floor_at(mesher: RefCounted, x: float, z: float, near_y: float) -> float:
    var y := near_y + 3.0
    while y > near_y - 3.0:
        if float(mesher.call("Sample", Vector3(x, y, z))) <= 0.0:
            return y
        y -= 0.02
    return NAN


func test_a_station_and_its_galleries_are_one_feature() -> void:
    var plan := MineLayout.generate(4242)
    var graph := MineLayout.graph(plan, MineLayout.dug(plan, {}, {}))
    var volumes: Array = graph.volumes
    var joined := 0
    for index in volumes.size():
        var volume: Dictionary = volumes[index]
        if bool(volume.get("joins_previous", false)):
            assert_eq(str(volume.kind), "tunnel", "a gallery's first segment")
            var before: Dictionary = volumes[index - 1]
            assert_true(str(before.kind) == "room" or str(before.kind) == "tunnel", "after its station or a gallery of it")
            joined += 1
    var primaries: int = plan.galleries.filter(func(g: Dictionary) -> bool: return int(g.parent) < 0).size()
    assert_eq(joined, primaries, "every gallery leaving a station is joined to it")
    # Cut down to a box at a gallery's far end, the feature is kept whole: the mesher gives the same rock there.
    var gallery: Dictionary = plan.galleries[0]
    var far := MineLayout.point_at(gallery, float(MineLayout.dug(plan, {}, {})[int(gallery.id)]))
    var near := MineLayout.graph_near(plan, MineLayout.dug(plan, {}, {}), AABB(far - Vector3.ONE, Vector3.ONE * 2.0))
    var kept_station := false
    for volume: Dictionary in near.volumes:
        if str(volume.kind) == "room":
            kept_station = true
    assert_true(kept_station, "the station comes with its gallery")
    if MineMesher.warm():
        var whole := MineMesher.configure(graph)
        var part := MineMesher.configure(near)
        for offset: Vector3 in [Vector3.ZERO, Vector3(0.5, 1.0, 0.3), Vector3(-0.7, 0.2, 0.6)]:
            assert_almost_eq(float(part.call("Sample", far + offset)), float(whole.call("Sample", far + offset)), 1.0e-6)


func test_the_ramp_folds_up_while_the_lift_runs() -> void:
    var lift := _lift(60.0, [])
    var system: Node3D = load("res://scenes/_universe/structures/industrial/truck_elevator/platform_system.tscn").instantiate()
    system.name = "Platform System"
    lift.add_child(system)
    system.add_child(load("res://scenes/_universe/structures/industrial/truck_elevator/platform.tscn").instantiate())
    var ramp := system.get_node_or_null("Platform/Ramp") as TruckElevatorRamp
    assert_not_null(ramp, "the platform has its ramp")
    if ramp == null:
        return
    var box := (ramp.get_node("Ramp Collider") as CollisionShape3D).shape as BoxShape3D
    assert_not_null(box, "a box of collision that turns with it")
    var laid := deg_to_rad(ramp.laid_deg)
    var folded := deg_to_rad(ramp.folded_deg)
    await wait_seconds(ramp.fold_time_s + 0.5)
    assert_almost_eq(ramp.rotation.x, folded, 1.0e-3, "folded up at the top: its front faces the shaft")
    lift.platform_progress_ratio = 50.0
    await wait_seconds(ramp.fold_time_s + 0.5)
    assert_almost_eq(ramp.rotation.x, laid, 1.0e-3, "laid down at 5 deg, stopped at a level")
    lift.apply_prop_data({"is_moving": true})
    await wait_seconds(ramp.fold_time_s + 0.5)
    assert_almost_eq(ramp.rotation.x, folded, 1.0e-3, "folded up while it runs")
    lift.apply_prop_data({"is_moving": false})
    await wait_seconds(ramp.fold_time_s + 0.5)
    assert_almost_eq(ramp.rotation.x, laid, 1.0e-3, "laid down again when it stops")


func test_a_landing_calls_the_platform_straight_to_itself() -> void:
    var lift := _lift(300.0, [40.0, 110.0, 190.0])
    # Two levels down, called from the top: straight up, not to the next level.
    lift.platform_progress_ratio = 190.0 / 3.0
    (lift.get_node("Upper Landing") as LiftLanding).update_screen({"elevator_screen_action": {"landing": "upper"}})
    assert_true(lift.is_moving())
    assert_almost_eq(lift._target_ratio, 0.0, 1.0e-4, "to the upper landing, past the levels")
    lift.stop_movement()
    lift._current_speed = 0.0
    # From the bottom, the platform at the first level: straight down.
    lift.platform_progress_ratio = 40.0 / 3.0
    (lift.get_node("Lower Landing") as LiftLanding).update_screen({"elevator_screen_action": {"landing": "lower"}})
    assert_almost_eq(lift._target_ratio, 100.0, 1.0e-4, "to the lower landing, past the levels")
    lift.stop_movement()
    lift._current_speed = 0.0
    # From a level: to that level.
    lift.platform_progress_ratio = 0.0
    (lift.get_node("StopLanding2") as LiftLanding).update_screen({"elevator_screen_action": {"landing": "upper"}})
    assert_almost_eq(lift._target_ratio, 190.0 / 3.0, 1.0e-3, "to the calling level")
    # The platform's own buttons still go stop by stop.
    lift.stop_movement()
    lift._current_speed = 0.0
    lift.platform_progress_ratio = 190.0 / 3.0
    lift.move_up()
    assert_almost_eq(lift._target_ratio, 110.0 / 3.0, 1.0e-3, "the platform's up button: the next level up")
