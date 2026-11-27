extends GutTest
## The test spaceship as a networked vehicle (Spaceship): what the garage terminal hands out and what the
## server flies. The scene is instantiated, not run (no game server here); the flight model is tested
## through its pure functions.

const SHIP := "res://scenes/_universe/vehicles/spaceship/spaceship.tscn"
const VEHICLE_DEF := "res://items_def/vehicle_def.json"
## Loaded by path: a class_name only exists once the project has been imported again.
const RIDER := preload("res://scenes/_universe/vehicles/spaceship/ship_interior_rider.gd")
const MASS := 1000.0
const THRUST := Vector3(12000.0, 15000.0, 20000.0)  # strafe, lift, forward
const RATES := Vector3(1.0, 0.8, 1.5)  # pitch, yaw, roll (rad/s)

var _ship: Spaceship = null


func before_each() -> void:
	_ship = (load(SHIP) as PackedScene).instantiate() as Spaceship


func after_each() -> void:
	if is_instance_valid(_ship):
		_ship.free()


func test_the_scene_is_a_networked_vehicle() -> void:
	assert_not_null(_ship, "the root is a Spaceship")
	assert_true(_ship is Vehicle, "a Vehicle: seats, camera, replication, hand-overs")
	assert_eq(_ship.type_name, "vehicle", "the truck's Horizon type and def: no Horizon change")
	assert_eq(MarkerSpawn.scene_type(load(SHIP)), "vehicle", "the garage terminal can hand it out")
	assert_eq(_ship.collision_layer, 1 << (Globals.LAYER_VEHICLE - 1), "on the vehicle layer")
	assert_eq(_ship.collision_mask & (1 << (Globals.LAYER_PLAYER - 1)), 0, "never scans the players")


func test_it_has_a_pilot_seat() -> void:
	var seat := _ship.get_node_or_null("SeatPilot") as VehicleSeat
	assert_not_null(seat, "a VehicleSeat named SeatPilot")
	if seat == null:
		return
	assert_true(seat.is_driver_seat(), "the pilot drives")
	assert_eq(seat.door_id, "", "no door to open first")
	assert_eq(seat.prompt_key, "%%HUD_PILOT_SHIP", "its own words on the prompt")
	assert_not_null(seat.get_node_or_null("SitPoint"), "where the pilot's eye sits")
	assert_eq(VehicleNetKey.of(seat), "seat_pilot", "its key in the replicated state")


func test_it_builds_no_wheel_no_blockout_and_no_bed() -> void:
	_ship._rebuild()  # what _ready does first
	assert_eq(_ship._wheels.size(), 0, "no wheels")
	assert_null(_ship.get_node_or_null("BlockoutVisual"), "the CSG hull is the model, not the truck's blockout")
	assert_null(_ship.get_node_or_null("CargoBay"), "no cargo bed")
	var generated: int = 0
	for child in _ship.get_children():
		if child is CollisionShape3D and child.has_meta(Vehicle.GENERATED):
			generated += 1
	assert_eq(generated, 0, "no generated collision: the scene's own box")
	assert_eq(_ship._driven_wheels_grounded(), false, "no wheel touches the ground")


func test_its_state_is_whitelisted_by_horizon() -> void:
	# A key Horizon does not index is dropped in silence (genericprops.rs), as for the truck.
	var def : Dictionary = JSON.parse_string(FileAccess.get_file_as_string(VEHICLE_DEF))
	var allowed : Array = []
	for channel in def["channels"]:
		allowed.append_array(channel["properties"])
	var sent : Dictionary = _ship.full_state()
	for part in _ship._net_parts():
		part.write_changes(sent)
	for key in sent:
		assert_has(allowed, key, "'%s' must be in vehicle_def.json" % key)
	assert_eq(sent["seats"], {"seat_pilot": ""}, "the pilot seat, free")


func test_the_flight_input_is_clamped_and_complete() -> void:
	var input: Dictionary = Spaceship.flight_input({"throttle": 3.0, "yaw": -2, "roll": "x", "brake": true})
	assert_eq(input["throttle"], 1.0, "clamped")
	assert_eq(input["yaw"], -1.0, "an int is a number too")
	assert_eq(input["roll"], 0.0, "not a number: nothing")
	assert_eq(input["lift"], 0.0, "missing: nothing")
	assert_true(input["brake"])
	assert_eq(input.size(), Spaceship.AXES.size() + 1, "every axis and the brake")


func test_thrust_goes_along_the_ships_own_axes() -> void:
	var still := Vector3.ZERO
	assert_eq(_force({"throttle": 1.0}, still), Vector3(0.0, 0.0, -THRUST.z), "forward is -Z")
	assert_eq(_force({"throttle": -1.0}, still), Vector3(0.0, 0.0, THRUST.z), "back is +Z")
	assert_eq(_force({"strafe": 1.0}, still), Vector3(THRUST.x, 0.0, 0.0), "right is +X")
	assert_eq(_force({"lift": 1.0}, still), Vector3(0.0, THRUST.y, 0.0), "up is +Y")
	assert_eq(_force({"lift": 5.0}, still), Vector3(0.0, THRUST.y, 0.0), "never more than full thrust")
	assert_eq(_force({}, still), Vector3.ZERO, "no input at rest: no thrust")


func test_engine_off_does_nothing() -> void:
	var moving := Vector3(3.0, -4.0, -5.0)
	assert_eq(Spaceship.flight_force({"throttle": 1.0}, moving, THRUST, 60.0, 8.0, 1.5, MASS, false), Vector3.ZERO)
	assert_eq(Spaceship.hover_force(Vector3(0.0, -7.0, 0.0), MASS, false), Vector3.ZERO, "no hover: it falls")
	var spin := Vector3(0.2, 0.3, 0.4)
	assert_eq(Spaceship.angular_step(spin, {"pitch": 1.0}, RATES, 10.0, 0.1, false), spin, "nothing steers it")


func test_the_hover_holds_the_ships_weight() -> void:
	var gravity := Vector3(0.0, -7.77, 0.0)
	var hover: Vector3 = Spaceship.hover_force(gravity, MASS, true)
	assert_almost_eq(hover.y, 7770.0, 0.01, "its weight, upward")
	assert_almost_eq((hover + gravity * MASS).length(), 0.0, 0.01, "gravity cancelled: it holds its altitude")


func test_the_assist_brings_a_released_axis_back_to_rest() -> void:
	var drifting := Vector3(0.0, 0.0, -10.0)  # 10 m/s forward, keys released
	var force: Vector3 = _force({}, drifting)
	assert_gt(force.z, 0.0, "pushed backwards, against the drift")
	assert_almost_eq(force.z, 8.0 * MASS, 0.01, "at most assist_decel")
	var slow: Vector3 = _force({}, Vector3(0.0, 0.0, -1.0))
	assert_almost_eq(slow.z, 1.5 * MASS, 0.01, "near rest, it follows the speed down")
	var braking: Vector3 = _force({"throttle": 1.0, "brake": true}, drifting)
	assert_gt(braking.z, 0.0, "the brake overrides the keys: no thrust, only the assist")


func test_no_thrust_past_top_speed() -> void:
	var flat_out := Vector3(0.0, 0.0, -60.0)  # forward at max_speed
	assert_eq(_force({"throttle": 1.0}, flat_out).z, 0.0, "no more forward push")
	assert_eq(_force({"throttle": -1.0}, flat_out).z, THRUST.z, "still slows down")


func test_the_turn_rates_have_the_right_sense() -> void:
	var nose_up: Vector3 = Spaceship.angular_step(Vector3.ZERO, {"pitch": 1.0}, RATES, 100.0, 1.0, true)
	assert_almost_eq(nose_up.x, RATES.x, 0.0001, "pitch about +X")
	assert_gt(nose_up.cross(Vector3.FORWARD).y, 0.0, "the nose (-Z) goes up")
	var nose_right: Vector3 = Spaceship.angular_step(Vector3.ZERO, {"yaw": 1.0}, RATES, 100.0, 1.0, true)
	assert_gt(nose_right.cross(Vector3.FORWARD).x, 0.0, "yaw +1: the nose goes right")
	var right_wing_down: Vector3 = Spaceship.angular_step(Vector3.ZERO, {"roll": 1.0}, RATES, 100.0, 1.0, true)
	assert_almost_eq(right_wing_down.z, -RATES.z, 0.0001, "roll about the forward axis")
	assert_lt(right_wing_down.cross(Vector3.RIGHT).y, 0.0, "roll +1: the right wing goes down")


func test_the_turn_rate_ramps_and_stops() -> void:
	var first: Vector3 = Spaceship.angular_step(Vector3.ZERO, {"pitch": 1.0}, RATES, 2.0, 0.1, true)
	assert_almost_eq(first.length(), 0.2, 0.0001, "angular_accel x delta per step")
	var spinning := Vector3(0.5, 0.0, 0.0)
	assert_eq(Spaceship.angular_step(spinning, {}, RATES, 100.0, 1.0, true), Vector3.ZERO, "released: back to zero")
	assert_eq(Spaceship.angular_step(spinning, {"pitch": 1.0, "brake": true}, RATES, 100.0, 1.0, true),
			Vector3.ZERO, "the brake stops the turn too")


func test_the_power_gauge_reads_the_strongest_axis() -> void:
	assert_eq(Spaceship.flight_power_share({"throttle": -0.5, "lift": 0.8, "pitch": 1.0}), 0.8, "turns are not thrust")
	assert_eq(Spaceship.flight_power_share({}), 0.0)


func test_the_mouse_steers_pitch_and_yaw_and_a_lock_sends_neutral() -> void:
	var locked: Dictionary = PlayerClient.flight_axes(Vector2(1.0, 1.0), true)
	assert_eq(locked["pitch"], 0.0, "a panel owns the input: neutral")
	assert_eq(locked["brake"], false)
	var look: Dictionary = PlayerClient.flight_axes(Vector2(-0.5, 2.0), false)
	assert_eq(look["pitch"], 1.0, "mouse up (look.y > 0): nose up, clamped")
	assert_eq(look["yaw"], 0.5, "mouse right (look.x < 0): nose right")
	assert_eq(Spaceship.flight_input(look)["yaw"], 0.5, "the server reads what the client sends")


## The ship-frame force for [param input] at [param local_velocity], with the test's tuning.
func _force(input: Dictionary, local_velocity: Vector3) -> Vector3:
	return Spaceship.flight_force(input, local_velocity, THRUST, 60.0, 8.0, 1.5, MASS, true)


func test_the_thrusters_puff_once_per_manoeuvre() -> void:
	assert_true(SpaceshipSound.puff_edge(0.5, 0.3, true), "a manoeuvre starts: a puff")
	assert_false(SpaceshipSound.puff_edge(0.5, 0.3, false), "held: no second puff")
	assert_false(SpaceshipSound.rearmed(0.5, 0.3, true), "past the threshold: disarmed")
	assert_false(SpaceshipSound.rearmed(0.2, 0.3, false), "just under it: still disarmed (hysteresis)")
	assert_true(SpaceshipSound.rearmed(0.05, 0.3, false), "released: armed again")


func test_the_thrust_loop_follows_the_thrust() -> void:
	var idle := SpaceshipSound.loop_mix(0.0, 0.0, 1.2)
	assert_eq(idle.x, SpaceshipSound.SILENT_DB, "no thrust: silent")
	var full := SpaceshipSound.loop_mix(1.0, -3.0, 1.2)
	assert_almost_eq(full.x, -3.0, 1e-4, "full thrust: its level")
	assert_almost_eq(full.y, 1.2, 1e-6, "and its pitch")
	assert_lt(SpaceshipSound.loop_mix(0.5, -3.0, 1.2).x, full.x, "half thrust: quieter")


func test_the_ship_scene_carries_its_sounds() -> void:
	var ship: Spaceship = load(SHIP).instantiate()
	assert_not_null(ship.sfx_engine_idle, "the engine's idle loop")
	assert_not_null(ship.sfx_engine_start, "its start")
	assert_not_null(ship.sfx_engine_stop, "its stop")
	var sound := ship.get_node("ThrusterSound") as SpaceshipSound
	assert_not_null(sound, "the thrusters' sound")
	assert_not_null(sound.thrust_loop)
	assert_eq(sound.puffs.size(), 4, "four puffs")
	ship.free()


func test_the_wheel_sets_the_top_speed() -> void:
	assert_almost_eq(Spaceship.capped_speed(512.0, 216.0), 60.0, 1e-4, "216 km/h: 60 m/s")
	assert_eq(Spaceship.capped_speed(512.0, 99999.0), 512.0, "never past the ship's top speed")
	assert_eq(Spaceship.capped_speed(512.0, 0.0), 1.0, "never a stop: the brake is for that")
	var ship: Spaceship = load(SHIP).instantiate()
	assert_almost_eq(ship.limiter.step_kmh / 3.6, 20.0, 0.01, "a notch of the wheel is 20 m/s")
	assert_gte(ship.limiter.max_kmh / 3.6, 511.0, "the wheel reaches the top speed")
	ship.free()


func test_the_limiter_off_lets_the_keys_reach_the_top_speed() -> void:
	assert_eq(Spaceship.key_top_speed(512.0, false, 216.0), 512.0, "off: the ship's own top speed")
	assert_almost_eq(Spaceship.key_top_speed(512.0, true, 216.0), 60.0, 1e-4, "on (T): its set speed")
	var at_cap := Vector3(0.0, 0.0, -100.0)  # 100 m/s forward, well past a 60 m/s limit
	var top_off: float = Spaceship.key_top_speed(512.0, false, 216.0)
	assert_eq(Spaceship.flight_force({"throttle": 1.0}, at_cap, THRUST, top_off, 8.0, 1.5, MASS, true).z, -THRUST.z,
			"limiter off: still full thrust at 100 m/s")
	var top_on: float = Spaceship.key_top_speed(512.0, true, 216.0)
	var held: Vector3 = Spaceship.flight_force({"throttle": 1.0}, at_cap, THRUST, top_on, 8.0, 1.5, MASS, true)
	assert_almost_eq(held.z, 8.0 * MASS, 0.01, "limiter on at speed: brought back down to it, key held")


func test_the_limiter_eases_off_near_its_speed() -> void:
	assert_eq(Spaceship.taper_share(10.0, 60.0, 1.0), 1.0, "far under: full thrust")
	assert_almost_eq(Spaceship.taper_share(59.5, 60.0, 1.0), 0.5, 1e-4, "half way into the taper: half")
	assert_eq(Spaceship.taper_share(60.0, 60.0, 1.0), 0.0, "at it: nothing")
	assert_eq(Spaceship.taper_share(59.9, 60.0, 0.0), 1.0, "no taper: full up to it")
	var near: Vector3 = Spaceship.flight_force({"throttle": 1.0}, Vector3(0.0, 0.0, -59.5), THRUST, 60.0, 8.0, 1.5,
			MASS, true, 1.0)
	assert_almost_eq(near.z, -THRUST.z * 0.5, 0.01, "the forward push tapers")


func test_the_cruise_holds_the_forward_speed_with_the_key_released() -> void:
	var cruise := _cruise()
	cruise.toggle(360.0)  # Ctrl+T at 100 m/s forward
	assert_true(cruise.enabled)
	var below: Dictionary = Spaceship.apply_cruise(Spaceship.flight_input({}), cruise, 350.0, true)
	assert_gt(below["throttle"], 0.0, "under the set speed: it pushes forward")
	assert_true(below[Spaceship.HOLD_FORWARD], "the forward axis is held")
	# Under the cruise the keys' top is the ship's own (512 m/s), not the helper's 60.
	var pushed: Vector3 = Spaceship.flight_force(below, Vector3(0.0, 0.0, -350.0 / 3.6), THRUST, 512.0, 8.0, 1.5,
			MASS, true)
	assert_lt(pushed.z, 0.0, "a forward (-Z) push")
	var at_speed: Dictionary = Spaceship.apply_cruise(Spaceship.flight_input({}), cruise, 365.0, true)
	assert_eq(at_speed["throttle"], 0.0, "at or over the set speed: no push")
	var coast: Vector3 = _force(at_speed, Vector3(1.0, 0.0, -365.0 / 3.6))
	assert_eq(coast.z, 0.0, "the assist does not brake the held forward axis to zero")
	assert_gt(-coast.x, 0.0, "the other axes keep their assist")
	var strafing: Dictionary = Spaceship.apply_cruise(Spaceship.flight_input({"strafe": 1.0}), cruise, 360.0, true)
	assert_eq(strafing["strafe"], 1.0, "strafe stays manual")
	assert_true(cruise.enabled, "strafing does not cancel it")


func test_the_cruise_is_cancelled_by_back_brake_and_engine_off() -> void:
	var cruise := _cruise()
	cruise.toggle(360.0)
	var back: Dictionary = Spaceship.apply_cruise(Spaceship.flight_input({"throttle": -1.0}), cruise, 360.0, true)
	assert_false(cruise.enabled, "back: off")
	assert_eq(back["throttle"], -1.0, "the key drives again")
	assert_false(back.get(Spaceship.HOLD_FORWARD, false), "nothing held any more")
	cruise.toggle(360.0)
	Spaceship.apply_cruise(Spaceship.flight_input({"brake": true}), cruise, 360.0, true)
	assert_false(cruise.enabled, "the brake: off")
	cruise.toggle(360.0)
	Spaceship.apply_cruise(Spaceship.flight_input({}), cruise, 360.0, false)
	assert_false(cruise.enabled, "engine off: off")
	var off: Dictionary = Spaceship.flight_input({"throttle": 0.5})
	assert_eq(Spaceship.apply_cruise(off, cruise, 360.0, true), off, "off: the pilot's input as is")


func test_the_cockpit_screen_is_the_dashboard_in_its_ship_layout() -> void:
	var dash := _ship.get_node_or_null("Gui3D/SubViewport/VehicleDashboard") as VehicleDashboard
	assert_not_null(dash, "the truck's dashboard, on the console")
	if dash == null:
		return
	assert_eq(dash.layout, VehicleDashboard.Layout.SHIP, "laid out for a ship")
	var gui: Node3D = _ship.get_node("Gui3D")
	assert_eq(gui.get("node_quad"), _ship.get_node("Gui3D/Screen"), "shown on its own quad")
	assert_false(gui.get("render_when_seen"), "the dashboard drives its viewport itself, like the truck's")
	var eye: Vector3 = (_ship.get_node("SeatPilot/SitPoint") as Node3D).transform.origin + \
			(_ship.get_node("SeatPilot") as Node3D).transform.origin
	var facing: Vector3 = gui.transform.basis.z
	assert_gt(facing.dot((eye - gui.transform.origin).normalized()), 0.95, "turned toward the pilot's eye")
	assert_true(VehicleDashboard.powered(VehicleDashboard.Layout.SHIP, true, false), "lit by the engine alone")
	assert_false(VehicleDashboard.powered(VehicleDashboard.Layout.SHIP, false, true), "dark with the engine off")
	assert_false(VehicleDashboard.powered(VehicleDashboard.Layout.TRUCK, true, false), "a truck needs a charge")
	for cell: String in ["handbrake", "doors", "load", "bays"]:
		assert_has(VehicleDashboard.hidden_cells(VehicleDashboard.Layout.SHIP), cell, "no dead '%s' light" % cell)
	assert_eq(VehicleDashboard.hidden_cells(VehicleDashboard.Layout.TRUCK).size(), 0, "the truck shows them all")


func test_the_ship_has_a_pair_of_head_lights() -> void:
	var lights: Array = []
	for light_name: String in ["HeadlightLeft", "HeadlightRight"]:
		var light := _ship.get_node_or_null(light_name) as SpotLight3D
		assert_not_null(light, light_name)
		if light == null:
			continue
		assert_true(light.is_in_group(Vehicle.LIGHT_GROUP), "%s is switched by L" % light_name)
		var beam: Vector3 = light.transform.basis * Vector3.FORWARD
		assert_lt(beam.y, 0.0, "%s points slightly down" % light_name)
		assert_lt(beam.z, -0.99, "%s points forward, along -Z" % light_name)
		assert_between(light.spot_range, 200.0, 500.0, "%s reaches far ahead of a fast ship, not across the map" % light_name)
		lights.append(light)
	assert_eq(lights.size(), 2)
	var grouped: int = 0
	for node in _ship.find_children("*", "Light3D", true, false):
		if node.is_in_group(Vehicle.LIGHT_GROUP):
			grouped += 1
	assert_gte(grouped, 2, "at least two lights in the group vehicle_light")
	assert_has(_ship.headlight_glass_materials, "ShipHeadlightGlass", "the lenses glow with them")


func test_the_hull_is_hollow_and_walkable() -> void:
	assert_null(_ship.get_node_or_null("Interior"), "no separate interior body: the root's compound is the hull")
	var floor_top: float = _box_top(_ship.get_node("HullFloor"))
	# A standing body (1.8 m) fits in the cabin, behind the seat, mid-cabin and at the top of the ramp.
	for z: float in [-1.6, -0.5, 0.5, 1.3]:
		for h: float in [0.05, 0.9, 1.8, 2.4]:
			var p := Vector3(0.0, floor_top + h, z)
			assert_false(_inside_hull(p), "%s is in the cabin, not in the hull" % str(p))
	assert_true(_inside_hull(Vector3(0.0, floor_top - 0.1, -1.0)), "a floor under the feet")
	assert_true(_inside_hull(Vector3(1.65, 1.2, 0.0)), "a wall on the side")
	assert_true(_inside_hull(Vector3(0.0, 2.75, 0.5)), "a roof overhead")
	assert_true(_inside_hull(Vector3(0.0, 0.5, -3.8)), "the dashboard in front")
	var bottom: float = _ship._nav_footprint_get().position.y
	assert_almost_eq(bottom, -0.51, 0.02, "it still rests on the ground as it did (garage bay, clearance)")


## The rear ramp is a door (Spaceship.RAMP_DOOR): shut, it stands up and closes the cabin; open, it lies
## down from the cabin floor to a step from the ground, and its collision follows the drawn leaf.
func test_the_rear_ramp_closes_the_cabin_and_opens_down_to_the_ground() -> void:
	assert_eq(_ship.door_ids(), PackedStringArray([Spaceship.RAMP_DOOR]), "the ramp is the ship's one door")
	var handle := _ship.get_node("RampHandle") as VehicleDoorHandle
	assert_eq(handle.prompt_open, "%%HUD_RAMP_OPEN", "it says ramp, not door")
	assert_eq(handle.wind_area_m2, 0.0, "the wind does not slam it")
	var ramp := _ship.get_node("HullRamp") as CollisionShape3D
	var pivot := _ship.get_node("Hull/Ramp") as Node3D
	var leaf := pivot.get_node(Spaceship.RAMP_LEAF) as CSGBox3D
	var half: Vector3 = (ramp.shape as BoxShape3D).size * 0.5
	assert_almost_eq(leaf.size, half * 2.0, Vector3.ONE * 0.001, "the drawn leaf is the collision's size")
	var floor_top: float = _box_top(_ship.get_node("HullFloor"))
	var ground: float = _ship._nav_footprint_get().position.y
	# Shut, as the scene stands: upright, from the floor to under the roof.
	assert_almost_eq(rad_to_deg(ramp.transform.basis.y.angle_to(Vector3.UP)), 0.0, 0.5, "shut: upright")
	assert_lt(ramp.transform.origin.y - half.y, floor_top + 0.01, "shut: from the floor")
	assert_gt(ramp.transform.origin.y + half.y, 2.5, "shut: up to the roof")
	assert_true(_inside_hull(Vector3(0.0, 1.0, ramp.transform.origin.z)), "shut: a wall across the opening")
	# Shut, the hold behind the pilot seat takes a truck (players drive one in), floor and walls all along.
	var truck: Vehicle = load("res://scenes/_universe/vehicles/ground/trucks/truck.tscn").instantiate()
	var seat_back: float = _ship.get_node("SeatPilot").transform.origin.z + 0.8
	var hold: float = ramp.transform.origin.z - half.z - seat_back
	assert_gt(hold, truck.body_length + 0.2, "the hold (%.2f m) takes the truck (%.2f m)" % [hold, truck.body_length])
	truck.free()
	for z: float in [seat_back + 0.2, 2.0, ramp.transform.origin.z - 0.2]:
		assert_true(_inside_hull(Vector3(0.0, floor_top - 0.1, z)), "a floor at z %.1f" % z)
		assert_true(_inside_hull(Vector3(1.6, 0.8, z)), "a wall at z %.1f" % z)  # under the cockpit's sill
		assert_false(_inside_hull(Vector3(0.0, floor_top + 1.0, z)), "room at z %.1f" % z)
	# Open, through the same path as a door swing (Vehicle._set_door_angle, from the rest _swing_door keeps).
	pivot.set_meta("rest_basis", pivot.transform.basis)
	_ship._set_door_angle(handle.open_angle_deg, pivot, handle.hinge_axis)
	var along: Vector3 = ramp.transform.basis.y.normalized()
	var slope: float = rad_to_deg(absf(asin(along.y)))
	assert_between(slope, 3.0, 30.0, "open: a gentle slope, walkable")
	var top_in: Vector3 = ramp.transform * Vector3(0.0, -half.y, -half.z)
	var top_out: Vector3 = ramp.transform * Vector3(0.0, half.y, -half.z)
	assert_almost_eq(top_in.y, floor_top, 0.06, "open: its upper end meets the cabin floor")
	assert_gt(top_out.z, top_in.z + 2.0, "open: it reaches out behind (+Z)")
	assert_between(top_out.y - ground, 0.0, 0.06, "open: its foot is walked onto, no step to jump")
	var foot_under: Vector3 = ramp.transform * Vector3(0.0, half.y, half.z)
	assert_gt(foot_under.y - ground, -0.01, "open: its foot does not dig into the ground (it would lift the hull)")
	assert_false(_inside_hull(Vector3(0.0, 1.0, top_in.z)), "open: the way in is clear")


func test_the_cabin_zone_makes_walkers_ride() -> void:
	var zone := _ship.get_node_or_null("InteriorZone") as Area3D
	assert_not_null(zone, "the cabin's zone")
	if zone == null:
		return
	assert_eq(zone.get_script(), RIDER, "ShipInteriorRider")
	assert_false(zone.monitoring, "off in the scene: the server turns it on, clients never scan")
	assert_false(zone.monitorable, "nothing scans it")
	assert_eq(zone.collision_layer, 0)
	assert_eq(zone.collision_mask, 1 << (Globals.LAYER_PLAYER - 1), "it looks for players only")
	var floor_top: float = _box_top(_ship.get_node("HullFloor"))
	assert_true(_inside_area(zone, Vector3(0.0, floor_top + 0.9, -1.0)), "the cabin is in it")
	assert_false(_inside_area(zone, Vector3(0.0, floor_top + 0.9, 4.0)), "behind the ramp is not")


func test_the_ship_has_its_own_gravity_over_the_planet() -> void:
	var grid := _ship.get_node_or_null("ShipPhysicsGrid") as Area3D
	assert_not_null(grid, "the ship's gravity")
	if grid == null:
		return
	assert_true(grid.is_in_group("gravity"), "a gravity area for the players' AreaDetector")
	assert_true(grid.monitorable, "seen by the players' AreaDetector")
	assert_eq(grid.collision_layer, 1 << (Globals.LAYER_ZONE - 1), "on the zone layer it scans")
	assert_false(grid.monitoring, "pulls no rigid body: the ship itself keeps the planet's gravity")
	assert_eq(grid.collision_mask, 0, "and could not: it overlaps no body")
	assert_false(grid.gravity_point, "directional, along the ship's -Y")
	assert_eq(grid.gravity_space_override, Area3D.SPACE_OVERRIDE_REPLACE)
	assert_gt(grid.priority, 0, "above a planet's sphere (priority 0): Player.pick_gravity_area")
	var floor_top: float = _box_top(_ship.get_node("HullFloor"))
	assert_true(_inside_area(grid, Vector3(0.0, floor_top + 0.9, -1.0)), "the cabin is in it")


func test_the_pilot_gets_up_in_the_cabin() -> void:
	var exit_point := _ship.get_node_or_null("ExitPoint") as Marker3D
	assert_not_null(exit_point, "where the pilot stands up")
	if exit_point == null:
		return
	var seat := _ship.get_node("SeatPilot") as Node3D
	assert_gt(exit_point.position.z, seat.position.z, "behind the seat")
	assert_false(_inside_hull(exit_point.position + Vector3(0.0, 0.9, 0.0)), "in the open cabin")
	assert_true(_inside_area(_ship.get_node("InteriorZone") as Area3D, exit_point.position + Vector3(0.0, 0.9, 0.0)),
			"in the cabin's zone: it keeps riding")
	assert_eq(_ship._exit_frame(), _ship, "it stays a child of the ship, not dropped outside in flight")


func test_a_walker_boards_and_leaves_after_a_grace() -> void:
	var state: Dictionary = {"riding": false, "count": 0}
	for i in RIDER.ENTER_GRACE_FRAMES - 1:
		state = RIDER.grace_step(state["riding"], true, state["count"])
	assert_false(state["riding"], "a brush of the cabin is not boarding")
	state = RIDER.grace_step(state["riding"], true, state["count"])
	assert_true(state["riding"], "inside long enough: it rides")
	for i in RIDER.EXIT_GRACE_FRAMES - 1:
		state = RIDER.grace_step(state["riding"], false, state["count"])
	assert_true(state["riding"], "a reparent's blink out of the zone does not drop it")
	state = RIDER.grace_step(state["riding"], true, state["count"])
	assert_eq(state["count"], 0, "back inside: the count starts again")
	for i in RIDER.EXIT_GRACE_FRAMES:
		state = RIDER.grace_step(state["riding"], false, state["count"])
	assert_false(state["riding"], "out long enough: handed back")


func test_a_riders_velocity_turns_with_the_ship() -> void:
	var before := Basis.IDENTITY
	var after := Basis(Vector3.UP, PI * 0.5)  # the ship yawed a quarter turn left
	var forward := Vector3(0.0, 0.0, -2.0)  # walking toward the nose
	var turned: Vector3 = RIDER.turned_velocity(forward, before, after)
	assert_almost_eq(turned.distance_to(after * forward), 0.0, 1e-5, "still toward the nose")
	assert_almost_eq(RIDER.turned_velocity(forward, after, after).distance_to(forward), 0.0, 1e-5, "no turn: unchanged")


func test_a_panel_freezes_the_flight_view() -> void:
	assert_eq(PlayerClient.flight_view(true, false), PlayerClient.FlightView.FROZEN, "a panel open: nothing steers")
	assert_eq(PlayerClient.flight_view(true, true), PlayerClient.FlightView.FROZEN, "even with aim held")
	assert_eq(PlayerClient.flight_view(false, true), PlayerClient.FlightView.FREE, "aim held: the mouse looks")
	assert_eq(PlayerClient.flight_view(false, false), PlayerClient.FlightView.STEER, "else it steers the ship")


## Whether [param p] (ship frame) is inside one of the hull's collision boxes.
func _inside_hull(p: Vector3) -> bool:
	for child in _ship.get_children():
		if child is CollisionShape3D and _inside_box(child as CollisionShape3D, p):
			return true
	return false


## Whether [param p] (ship frame) is inside a box shape of [param area] (a direct child of the ship).
func _inside_area(area: Area3D, p: Vector3) -> bool:
	for child in area.get_children():
		if child is CollisionShape3D and _inside_box(child as CollisionShape3D, area.transform.affine_inverse() * p):
			return true
	return false


## Whether [param p] (in the shape's parent frame) is inside [param cs], a BoxShape3D.
func _inside_box(cs: CollisionShape3D, p: Vector3) -> bool:
	if not (cs.shape is BoxShape3D) or cs.disabled:
		return false
	var local: Vector3 = cs.transform.affine_inverse() * p
	var half: Vector3 = (cs.shape as BoxShape3D).size * 0.5
	return absf(local.x) <= half.x and absf(local.y) <= half.y and absf(local.z) <= half.z


## The top (ship frame, m) of an axis-aligned box shape.
func _box_top(cs: CollisionShape3D) -> float:
	return cs.transform.origin.y + (cs.shape as BoxShape3D).size.y * 0.5


## A cruise control tuned like the ship's (its limiter steps: 72 km/h a notch, up to 1843 km/h).
func _cruise() -> VehicleCruiseControl:
	var cruise := VehicleCruiseControl.new()
	cruise.step_kmh = 72
	cruise.min_kmh = 72
	cruise.max_kmh = 1843
	return cruise
