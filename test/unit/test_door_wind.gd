extends GutTest
## The relative wind slams an open cab door shut once the truck goes fast enough, or a gust does on a
## parked truck (DoorWind), with the air's density taken from the planet's atmosphere at the vehicle's
## altitude (AtmosphereProfile).

const WIND := preload("res://scenes/_universe/vehicles/door_wind.gd")
const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"
## The truck's cab door: 1 m2, 0.9 m wide, open at 60°, a 25 N.m door check.
const AREA := 1.0
const WIDTH := 0.9
const OPEN := 60.0
const HOLD := 25.0
## The air on a door is the weather's wind minus the truck's velocity, vehicle frame (forward = -Z,
## right = +X). The truck's cab doors are hinged at their front edge: wind_shut_travel = FORWARD.
const RIGHT_DOOR := Vector3(0.9, 1.0, -1.0)
const LEFT_DOOR := Vector3(-0.9, 1.0, -1.0)
## Air density on Tarsis 3's reference sphere (kg/m3).
const RHO := 1.265


## Tarsis 3 from its system JSON: 1.02 bar, g 7.77 m/s2, scale height 10371 m.
func _tarsis_3_air() -> AtmosphereProfile:
	var air := AtmosphereProfile.new()
	air.surface_pressure_pa = 102000.0
	air.gravity = 7.774705784062155
	air.rayleigh_scale_height = 10371.042640756335
	return air


func test_the_air_thins_with_altitude() -> void:
	var air := _tarsis_3_air()
	assert_almost_eq(air.air_density(0.0), 1.265, 0.005, "the reference sphere: the 1.26 it replaces")
	assert_almost_eq(air.air_density(5130.0), 0.771, 0.005, "the villages")
	assert_eq(AtmosphereProfile.new().air_density(0.0), 0.0, "no pressure imported: nothing to say")


func test_the_cab_door_shuts_near_33_km_h_and_later_up_on_the_plateau() -> void:
	var air := _tarsis_3_air()
	var low : float = WIND.shutting_speed_kmh(air.air_density(0.0), AREA, WIDTH, OPEN, HOLD)
	var high : float = WIND.shutting_speed_kmh(air.air_density(5130.0), AREA, WIDTH, OPEN, HOLD)
	assert_almost_eq(low, 33.0, 1.0)
	assert_almost_eq(high, 42.4, 1.0, "thinner air, a harder push needed")


func test_the_torque_grows_with_the_square_of_the_speed() -> void:
	var at_10 : float = WIND.torque_nm(1.265, 10.0, AREA, WIDTH, OPEN)
	assert_almost_eq(WIND.torque_nm(1.265, 20.0, AREA, WIDTH, OPEN), 4.0 * at_10, 0.001)
	assert_eq(WIND.torque_nm(1.265, -10.0, AREA, WIDTH, OPEN), 0.0, "reversing opens nothing and shuts nothing")
	assert_eq(WIND.torque_nm(1.265, 10.0, AREA, WIDTH, 0.0), 0.0, "a shut door has no face to the wind")


## Torque towards shut on a cab door at [param door_pos] from the air [param air_ms] on it.
func _torque(air_ms: Vector3, door_pos: Vector3) -> float:
	var push : Vector3 = WIND.push_direction(Vector3.FORWARD, Vector3.UP, door_pos, OPEN)
	return WIND.torque_from_air_nm(RHO, air_ms, push, AREA, WIDTH)


## The truck's velocity, in the vehicle frame, driving forward at [param kmh].
func _driving(kmh: float) -> Vector3:
	return Vector3.FORWARD * kmh / 3.6


func test_still_air_while_driving_is_the_old_model() -> void:
	for door: Vector3 in [RIGHT_DOOR, LEFT_DOOR]:
		assert_almost_eq(_torque(-_driving(40.0), door), WIND.torque_nm(RHO, 40.0 / 3.6, AREA, WIDTH, OPEN), 1e-6,
				"air straight from the front: the same torque as before")


func test_parked_a_strong_wind_from_the_right_shuts_the_right_door() -> void:
	var from_right := Vector3.LEFT * 20.0  # the air moves leftward: it comes from the right
	assert_gt(_torque(from_right, RIGHT_DOOR), HOLD, "it hits the outer face: the door slams")
	assert_eq(_torque(from_right, LEFT_DOOR), 0.0, "the far door gets it on its inner face: held open")


func test_parked_in_calm_air_the_door_stays_open() -> void:
	assert_eq(_torque(Vector3.ZERO, RIGHT_DOOR), 0.0)
	assert_lt(_torque(Vector3.LEFT * 3.0, RIGHT_DOOR), HOLD, "a breeze does not beat the door check")


func test_a_head_wind_adds_to_the_speed() -> void:
	var still : float = _torque(-_driving(25.0), LEFT_DOOR)
	assert_lt(still, HOLD, "25 km/h in still air: below the 33 km/h it takes")
	var head_wind := Vector3.BACK * 5.0  # the air moves rearward: it comes from the front
	assert_gt(_torque(head_wind - _driving(25.0), LEFT_DOOR), HOLD, "into an 18 km/h head wind: it slams")


func test_a_tail_wind_cancels_the_speed() -> void:
	assert_gt(_torque(-_driving(40.0), LEFT_DOOR), HOLD, "40 km/h in still air: it slams")
	var tail_wind := Vector3.FORWARD * 40.0 / 3.6  # the air moves with the truck
	assert_almost_eq(_torque(tail_wind - _driving(40.0), LEFT_DOOR), 0.0, 1e-6, "a 40 km/h tail wind: no air on it")


func test_a_door_on_the_centre_line_takes_the_travel_part_only() -> void:
	var push : Vector3 = WIND.push_direction(Vector3.FORWARD, Vector3.UP, Vector3(0.0, 1.0, 2.0), OPEN)
	assert_almost_eq(push.distance_to(Vector3.BACK * sin(deg_to_rad(OPEN))), 0.0, 1e-6,
			"no side to tell: air from the front only")


## A future vehicle needs nothing set: its "<where>_door"s catch the wind, its hatches do not.
func test_doors_catch_the_wind_by_their_name() -> void:
	assert_true(WIND.by_default("front_l_door"))
	assert_true(WIND.by_default("rear_door"))
	assert_false(WIND.by_default("hatch_fl"), "a bay hatch, under the bed")


func test_a_leaf_is_measured_from_the_door_s_box() -> void:
	var leaf : Vector2 = WIND.leaf_of(AABB(Vector3.ZERO, Vector3(0.08, 1.2, 0.95)), Vector3.UP)
	assert_almost_eq(leaf.x, 1.14, 0.001, "height along the hinge x width")
	assert_almost_eq(leaf.y, 0.95, 0.001, "the width, not the thickness")


## Measured from the truck's own model: the leaves Vehicle.door_leaf takes for its cab doors (it finds
## the mesh through the scene tree; a test truck is not in it, so the meshes are looked up here).
func test_the_truck_s_cab_doors_are_measured_from_its_model() -> void:
	var truck : Vehicle = (load(TRUCK) as PackedScene).instantiate() as Vehicle
	var model : Node = truck.get_node("Model")
	for handle: VehicleDoorHandle in truck.find_children("*", "VehicleDoorHandle", true, false):
		if not WIND.by_default(handle.door_id):
			continue
		# Matched without case, as Vehicle._door_mesh does: the GLB names it Front_l_door.
		var door := model.find_children("*", "Node3D", true, false).filter(
				func(n: Node) -> bool: return String(n.name).to_lower() == handle.door_id)
		assert_false(door.is_empty(), "%s: its mesh is in the model" % handle.door_id)
		if door.is_empty():
			continue
		var leaf : Vector2 = WIND.leaf_of(WIND.mesh_aabb(door[0] as Node3D), Vector3.UP)
		assert_between(leaf.x, 0.5, 2.5, "%s: a cab door's area (m2)" % handle.door_id)
		assert_between(leaf.y, 0.5, 1.5, "%s: its width (m)" % handle.door_id)
		gut.p("%s: %.2f m2, %.2f m wide, shuts at %.0f km/h (air 1.265) / %.0f km/h (0.771)" % [
				handle.door_id, leaf.x, leaf.y,
				WIND.shutting_speed_kmh(1.265, leaf.x, leaf.y, handle.open_angle_deg, handle.wind_hold_nm),
				WIND.shutting_speed_kmh(0.771, leaf.x, leaf.y, handle.open_angle_deg, handle.wind_hold_nm)])
	truck.free()
