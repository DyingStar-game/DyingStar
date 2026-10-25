extends GutTest
## The truck bed is read off the model's own bed collision (col_bed, col_bed_left/right/rear), raised
## by the headroom over the side boards -- no box placed by hand. A drop point inside it loads.

const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"
const CRATE := "res://scenes/_universe/props/containers/box_50cm.tscn"


func test_the_bed_box_rises_by_the_headroom() -> void:
	var bed := AABB(Vector3(-0.9, 0.0, 0.1), Vector3(1.8, 0.65, 2.0))
	var box: AABB = Vehicle.bay_box(bed, 0.4, Vector3.ONE, Vector3.ZERO)
	assert_eq(box.position, bed.position)
	assert_almost_eq(box.size, Vector3(1.8, 1.05, 2.0), Vector3(1e-6, 1e-6, 1e-6))


func test_without_bed_pieces_the_hand_set_box_is_used() -> void:
	var box: AABB = Vehicle.bay_box(AABB(), 0.4, Vector3(2.0, 1.0, 3.0), Vector3(0.0, 1.0, 0.5))
	assert_almost_eq(box.get_center(), Vector3(0.0, 1.0, 0.5), Vector3(1e-6, 1e-6, 1e-6), "a blockout")
	assert_eq(box.size, Vector3(2.0, 1.0, 3.0))


func test_the_box_holds_every_corner_of_the_pieces() -> void:
	var points := PackedVector3Array([Vector3(1, 0, 0), Vector3(-1, 2, 3), Vector3(0, -1, 1)])
	var box: AABB = Vehicle.points_box(points)
	assert_eq(box.position, Vector3(-1, -1, 0))
	assert_eq(box.end, Vector3(1, 2, 3))
	assert_false(Vehicle.points_box(PackedVector3Array()).has_volume(), "no pieces, no box")


func test_the_truck_reads_its_bed_off_its_model() -> void:
	var truck: Vehicle = (load(TRUCK) as PackedScene).instantiate() as Vehicle
	truck.freeze = true
	add_child_autofree(truck)
	var box: AABB = truck._bay_box()
	assert_true(truck._bed_box.has_volume(), "the GLB carries col_bed pieces")
	assert_true(truck.is_point_in_loading_zone(truck.to_global(truck._bed_box.get_center())), "the bed's middle loads")
	assert_true(truck.is_point_in_loading_zone(truck.to_global(
			Vector3(box.get_center().x, truck._bed_box.end.y + 0.2, box.get_center().z))), "a crate proud of the boards loads")
	assert_false(truck.is_point_in_loading_zone(truck.to_global(Vector3(0.0, 0.3, -1.5))), "the cab does not")
	assert_false(truck.is_point_in_loading_zone(truck.to_global(Vector3(box.end.x + 0.5, 0.3, 1.0))), "beside the bed does not")


## The diamond-plate floor of mini_truck.glb, in the truck's frame (the model sits 0.435 m up, the plate
## at -0.002 in the model). The model's col_bed was 9 cm under it: truck.tscn raises it to the plate.
const VISIBLE_BED_FLOOR_Y := 0.433


func test_a_load_rests_on_the_visible_bed_floor() -> void:
	var truck: Vehicle = (load(TRUCK) as PackedScene).instantiate() as Vehicle
	truck.freeze = true
	add_child_autofree(truck)
	assert_almost_eq(truck._bed_floor_local_y(), VISIBLE_BED_FLOOR_Y, 0.005, "the floor is the model's, not the blockout's")
	var crate := (load(CRATE) as PackedScene).instantiate() as RigidBody3D
	add_child_autofree(crate)
	crate.global_position = truck.to_global(Vector3(0.0, 1.5, 1.0))
	assert_true(truck.lock_dropped_cargo(crate))
	var underside: float = Globals.collision_aabb(crate, truck.global_transform.affine_inverse() * crate.global_transform).position.y
	assert_almost_eq(underside, VISIBLE_BED_FLOOR_Y, 0.005, "neither sunk into the floor nor floating")


func test_the_boards_trim_the_floor() -> void:
	var floor_piece := AABB(Vector3(-1.0, 0.0, 0.0), Vector3(2.0, 0.1, 2.0))
	var pieces: Array[AABB] = [
		AABB(Vector3(-0.95, 0.0, 0.0), Vector3(0.1, 0.6, 2.0)),  # left board
		floor_piece,
		AABB(Vector3(0.85, 0.0, 0.0), Vector3(0.1, 0.6, 2.0)),  # right board
		AABB(Vector3(-1.0, 0.0, 1.9), Vector3(2.0, 0.6, 0.1)),  # rear board
	]
	var inside: AABB = Vehicle.bed_floor(pieces)
	assert_almost_eq(inside.position, Vector3(-0.85, 0.0, 0.0), Vector3(1e-6, 1e-6, 1e-6))
	assert_almost_eq(inside.end, Vector3(0.85, 0.1, 1.9), Vector3(1e-6, 1e-6, 1e-6), "the floor's top, between the boards")
	assert_false(Vehicle.bed_floor([] as Array[AABB]).has_volume(), "no pieces, no floor")


func test_a_load_dropped_towards_the_cab_lands_between_the_boards() -> void:
	var truck: Vehicle = (load(TRUCK) as PackedScene).instantiate() as Vehicle
	truck.freeze = true
	add_child_autofree(truck)
	var inside: AABB = truck._bed_floor
	assert_lt(inside.size.x, truck._bed_box.size.x - 0.1, "the side boards are taken off")
	var crate := (load(CRATE) as PackedScene).instantiate() as RigidBody3D
	add_child_autofree(crate)
	crate.global_position = truck.to_global(Vector3(inside.end.x, 1.5, inside.position.z - 0.3))
	assert_true(truck.lock_dropped_cargo(crate))
	var box: AABB = Globals.collision_aabb(crate, truck.global_transform.affine_inverse() * crate.global_transform)
	assert_true(box.position.z >= inside.position.z - 0.001, "not into the cab")
	assert_true(box.end.x <= inside.end.x + 0.001, "not into the side board")
