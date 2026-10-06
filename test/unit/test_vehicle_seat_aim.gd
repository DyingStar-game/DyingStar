extends GutTest
## A seat is boarded by LOOKING at it (the InteractRay, like a door handle), not by standing in a box
## beside the cab: its box sits on the seat itself, on the `interactable` layer, and the server checks
## reach (VehicleSeat.within_reach) and sight before it seats anyone.

const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"
const INTERACTABLE := 1 << (Globals.LAYER_INTERACTABLE - 1)

var _truck : Vehicle


func before_each() -> void:
	_truck = (load(TRUCK) as PackedScene).instantiate() as Vehicle


func after_each() -> void:
	_truck.free()


func _seats() -> Array[Node]:
	return _truck.find_children("*", "VehicleSeat", false, false)


func test_the_truck_s_seats_are_look_at_targets() -> void:
	assert_eq(_seats().size(), 2)
	for seat: VehicleSeat in _seats():
		assert_eq(seat.collision_layer, INTERACTABLE, "%s on the layer the InteractRay scans" % seat.name)
		assert_false(seat.monitoring, "%s runs no overlap pass of its own" % seat.name)


## The box is the seat: around where the occupant sits, inside the cab — not a patch of ground beside it.
func test_each_box_sits_on_its_seat_inside_the_cab() -> void:
	for seat: VehicleSeat in _seats():
		var box := seat.find_children("*", "CollisionShape3D", false, false)[0] as CollisionShape3D
		var sit := seat.get_node("SitPoint") as Marker3D
		var box_local : Vector3 = seat.transform * box.position
		var sit_local : Vector3 = seat.transform * sit.position
		assert_lt(box_local.distance_to(sit_local), 0.6, "%s: the box is where you sit" % seat.name)
		assert_lt(absf(box_local.x), _truck.body_width * 0.5, "%s: inside the body" % seat.name)


func test_a_request_names_its_seat_by_its_network_key() -> void:
	for seat: VehicleSeat in _seats():
		assert_eq(_truck.find_seat(VehicleNetKey.of(seat)), seat)
	assert_null(_truck.find_seat("no_such_seat"))


func test_the_server_seats_you_only_within_reach() -> void:
	var seat := VehicleSeat.new()
	var box := CollisionShape3D.new()
	box.shape = BoxShape3D.new()
	box.position = Vector3(0, 1, 0)
	seat.add_child(box)
	add_child_autofree(seat)
	assert_eq(seat.aim_point(), Vector3(0, 1, 0), "the middle of its box")
	assert_true(seat.within_reach(Vector3(0, 1, 2.5)), "beside the open door")
	assert_false(seat.within_reach(Vector3(0, 1, VehicleSeat.REACH_M + 0.5)), "from across the yard")
