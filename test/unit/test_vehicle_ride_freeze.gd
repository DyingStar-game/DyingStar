extends GutTest
## A client replica of a truck created already on a moving carrier (parked on a lift's platform when the player
## arrives) rides it KINEMATIC, as one driven onto it does (Vehicle.client_parent_change). Left STATIC, the physics
## server wrote its pose back every step while the interpolator moved it: it hopped on the mine's lift (2026-11-12).

const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"


func _replica_under(carrier: Node3D) -> Vehicle:
	var truck: Vehicle = (load(TRUCK) as PackedScene).instantiate()
	ReplicaDress.prepare(truck)  # frozen, as client.gd dresses every replica
	truck.uuid = "test-truck"
	carrier.add_child(truck)
	return truck


func test_created_on_a_lift_it_rides_kinematic() -> void:
	var system := Node3D.new()
	system.add_to_group(PropNet.RIDE_CARRIER_GROUP)
	add_child_autofree(system)
	var truck := _replica_under(system)
	assert_true(truck.freeze, "a replica")
	assert_eq(truck.freeze_mode, RigidBody3D.FREEZE_MODE_KINEMATIC)


func test_created_on_the_ground_it_stays_static() -> void:
	var ground := Node3D.new()
	add_child_autofree(ground)
	var truck := _replica_under(ground)
	assert_eq(truck.freeze_mode, RigidBody3D.FREEZE_MODE_STATIC)



func test_a_position_of_the_previous_frame_is_not_applied_after_a_reparent() -> void:
	# The network extension joins the new parent_id of a prop's update with the last transform it holds, still in
	# the old frame: the truck stood a moment 6000 km away on driving onto the lift (playtest 2026-11-12).
	var ground := Node3D.new()
	ground.position = Vector3(100, 0, 0)
	add_child_autofree(ground)
	var truck := _replica_under(ground)
	truck.client_channel_data_update({"position": {"x": 4450680.0, "y": 2674067.0, "z": 3675744.0}})
	var system := Node3D.new()
	system.add_to_group(PropNet.RIDE_CARRIER_GROUP)
	system.position = Vector3(4450780.0, 2674067.0, 3675744.0)
	add_child_autofree(system)
	truck.client_parent_change(system)
	var placed := truck.position
	assert_lt(placed.length(), 1.0, "the reparent keeps it where it stood: near the system's origin")
	truck.client_channel_data_update({"position": {"x": 4450680.0, "y": 2674067.0, "z": 3675744.0}})
	assert_eq(truck.position, placed, "the old frame's position, delivered with the new parent: skipped")
	truck.client_channel_data_update({"position": {"x": 0.5, "y": 0.3, "z": -1.5}})
	assert_almost_eq(truck.position, Vector3(0.5, 0.3, -1.5), Vector3.ONE * 1.0e-6, "the new frame's: applied")
