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


## A prop a player could carry, or not (a whole rock: carriable once cut down to size).
class Loadable extends RigidBody3D:
	var carriable_now := true

	func can_be_carried() -> bool:
		return carriable_now


func test_only_what_a_player_could_carry_rides_in_the_bed() -> void:
	var piece := Loadable.new()
	piece.add_to_group("carriable")
	assert_true(Vehicle.is_loadable(piece), "a piece cut down to size")
	piece.carriable_now = false
	assert_false(Vehicle.is_loadable(piece), "a whole rock backed into: not a load")
	var scenery := RigidBody3D.new()
	assert_false(Vehicle.is_loadable(scenery), "nothing a player carries")
	piece.free()
	scenery.free()


## The bed grid (playtest 2026-11-10): crates square to the bed, one layer, never inside each other.
func test_a_crate_is_squared_to_the_bed() -> void:
	var askew := Basis(Vector3.UP, deg_to_rad(80.0)) * Basis(Vector3.RIGHT, deg_to_rad(12.0))
	var square := Vehicle.square_basis(askew)
	assert_almost_eq(square.y, Vector3.UP, Vector3(1e-6, 1e-6, 1e-6), "upright")
	assert_almost_eq(square.z, Vector3(1.0, 0.0, 0.0), Vector3(1e-6, 1e-6, 1e-6), "a quarter turn")


func test_the_bed_fills_cell_by_cell_then_refuses() -> void:
	var room := AABB(Vector3(-0.85, 0.0, 0.0), Vector3(1.7, 0.1, 2.0))
	var size := Vector2(0.5, 0.5)
	var taken: Array[AABB] = []
	var cells := 0
	while true:
		var cell: Variant = Vehicle.bed_slot(room, size, Vector2(0.0, 1.0), taken)
		if cell == null:
			break
		var c := cell as Vector2
		for other in taken:
			assert_false(Rect2(c - size * 0.5, size).grow(-0.005).intersects(
					Rect2(other.position.x, other.position.z, other.size.x, other.size.z)), "no overlap")
		taken.append(AABB(Vector3(c.x - 0.25, 0.1, c.y - 0.25), Vector3(0.5, 0.5, 0.5)))
		cells += 1
		assert_lt(cells, 100, "it ends")
		if cells >= 100:
			break
	assert_eq(cells, 3 * 4, "3 across, 4 along (2 m for four 0.5 m crates, exactly): one layer")


func test_a_crate_takes_the_free_cell_nearest_the_aim() -> void:
	var room := AABB(Vector3(-0.85, 0.0, 0.0), Vector3(1.7, 0.1, 2.0))
	var first: Vector2 = Vehicle.bed_slot(room, Vector2(0.5, 0.5), Vector2(0.8, 1.9), [] as Array[AABB])
	assert_gt(first.x, 0.0, "towards the aim")
	assert_gt(first.y, 1.0, "towards the aim")


func test_two_crates_dropped_at_the_same_spot_sit_side_by_side() -> void:
	var truck: Vehicle = (load(TRUCK) as PackedScene).instantiate() as Vehicle
	truck.freeze = true
	add_child_autofree(truck)
	var boxes: Array[AABB] = []
	for i in 2:
		var crate := (load(CRATE) as PackedScene).instantiate() as RigidBody3D
		add_child_autofree(crate)
		crate.global_transform = truck.global_transform * Transform3D(Basis(Vector3.UP, 0.3), Vector3(0.0, 1.5, 1.0))
		assert_true(truck.lock_dropped_cargo(crate))
		boxes.append(Globals.collision_aabb(crate, truck.global_transform.affine_inverse() * crate.global_transform))
	assert_false(boxes[0].grow(-0.005).intersects(boxes[1]), "not inside each other")
	assert_almost_eq(boxes[0].position.y, boxes[1].position.y, 0.005, "both on the floor")


func test_a_rock_piece_takes_a_cell_never_inside_a_crate() -> void:
	var truck: Vehicle = (load(TRUCK) as PackedScene).instantiate() as Vehicle
	truck.freeze = true
	add_child_autofree(truck)
	var crate := (load(CRATE) as PackedScene).instantiate() as RigidBody3D
	add_child_autofree(crate)
	var aim := truck._bed_floor.get_center() + Vector3(0.0, 1.0, 0.0)
	crate.global_position = truck.to_global(aim)
	assert_true(truck.lock_dropped_cargo(crate))
	var rock := Loadable.new()
	rock.add_to_group("carriable")
	var hull := CollisionShape3D.new()
	hull.shape = SphereShape3D.new()
	(hull.shape as SphereShape3D).radius = 0.2
	rock.add_child(hull)
	add_child_autofree(rock)
	rock.global_transform = truck.global_transform * Transform3D(Basis(Vector3.UP, 0.3), aim)
	assert_false(Vehicle.is_boxy(rock), "a rock is not squared")
	assert_true(truck.lock_dropped_cargo(rock))
	var into := truck.global_transform.affine_inverse()
	var a: AABB = Globals.collision_aabb(crate, into * crate.global_transform)
	var b: AABB = Globals.collision_aabb(rock, into * rock.global_transform)
	assert_false(a.grow(-0.005).intersects(b), "dropped on the crate: beside it, not inside")



func test_a_turned_rock_piece_rests_on_the_floor_by_its_own_shape() -> void:
	# Its box's corners, turned, reached under the piece: it was set down floating.
	var truck: Vehicle = (load(TRUCK) as PackedScene).instantiate() as Vehicle
	truck.freeze = true
	add_child_autofree(truck)
	var rock := Loadable.new()
	rock.add_to_group("carriable")
	var hull := CollisionShape3D.new()
	hull.shape = ConvexPolygonShape3D.new()
	(hull.shape as ConvexPolygonShape3D).points = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(0.5, 0, 0), Vector3(0, 0.5, 0), Vector3(0, 0, 0.2), Vector3(0.5, 0, 0.2), Vector3(0, 0.5, 0.2)])
	rock.add_child(hull)
	add_child_autofree(rock)
	var turned := Basis(Vector3(1, 0, 1).normalized(), 0.9)
	rock.global_transform = truck.global_transform * Transform3D(turned, truck._bed_floor.get_center() + Vector3(0, 1, 0))
	assert_true(truck.lock_dropped_cargo(rock))
	var lowest := INF
	var into: Transform3D = truck.global_transform.affine_inverse() * rock.global_transform
	for point in (hull.shape as ConvexPolygonShape3D).points:
		lowest = minf(lowest, (into * point).y)
	assert_almost_eq(lowest, truck._bed_floor_local_y(), 0.002, "its lowest point on the floor")



func test_a_load_is_not_set_down_into_what_already_rides_the_bed() -> void:
	# A crate that came back with the truck from a restart: its child, not counted by the bed yet.
	var truck: Vehicle = (load(TRUCK) as PackedScene).instantiate() as Vehicle
	truck.freeze = true
	add_child_autofree(truck)
	var riding := (load(CRATE) as PackedScene).instantiate() as RigidBody3D
	riding.freeze = true
	truck.add_child(riding)
	var at := truck._bed_floor.get_center() + Vector3(0.0, 0.3, 0.0)
	riding.position = at
	var crate := (load(CRATE) as PackedScene).instantiate() as RigidBody3D
	add_child_autofree(crate)
	crate.global_position = truck.to_global(at + Vector3(0.0, 1.0, 0.0))
	assert_true(truck.lock_dropped_cargo(crate))
	var into := truck.global_transform.affine_inverse()
	var a: AABB = Globals.collision_aabb(riding, riding.transform)
	var b: AABB = Globals.collision_aabb(crate, into * crate.global_transform)
	assert_false(Rect2(a.position.x, a.position.z, a.size.x, a.size.z).grow(-0.005).intersects(
			Rect2(b.position.x, b.position.z, b.size.x, b.size.z)), "beside it, not into it")



## A load with no cell left lies where physics set it down, and is locked there (playtest 2026-11-10).
func test_a_load_at_rest_is_locked_where_it_lies() -> void:
	var truck: Vehicle = (load(TRUCK) as PackedScene).instantiate() as Vehicle
	truck.freeze = true
	add_child_autofree(truck)
	var crate := (load(CRATE) as PackedScene).instantiate() as RigidBody3D
	add_child_autofree(crate)
	crate.add_to_group("carriable")
	var lying := Transform3D(Basis(Vector3(1, 0, 1).normalized(), 0.4), truck._bed_floor.get_center() + Vector3(0.1, 0.9, 0.05))
	crate.global_transform = truck.global_transform * lying
	assert_true(truck.lock_resting_cargo(crate))
	var now: Transform3D = truck.global_transform.affine_inverse() * crate.global_transform
	assert_almost_eq(now.origin, lying.origin, Vector3.ONE * 1e-4, "not moved to a cell")
	assert_almost_eq(now.basis.x, lying.basis.x, Vector3.ONE * 1e-4, "nor turned")
	assert_true(truck._locked_cargo.has(crate), "counted in the load")


func test_what_lies_on_a_load_is_told_from_its_neighbours() -> void:
	var lower := AABB(Vector3(0, 0, 0), Vector3(0.4, 0.4, 0.4))
	assert_true(Vehicle.rests_on(AABB(Vector3(0.2, 0.4, 0.1), Vector3(0.4, 0.4, 0.4)), lower), "on top, half over it")
	assert_false(Vehicle.rests_on(AABB(Vector3(0.5, 0.0, 0.0), Vector3(0.4, 0.4, 0.4)), lower), "beside it on the floor")
	assert_false(Vehicle.rests_on(AABB(Vector3(1.0, 0.4, 0.0), Vector3(0.4, 0.4, 0.4)), lower), "higher, but over another")


func test_taking_a_load_frees_what_lay_on_it() -> void:
	var truck: Vehicle = (load(TRUCK) as PackedScene).instantiate() as Vehicle
	truck.freeze = true
	add_child_autofree(truck)
	var under := (load(CRATE) as PackedScene).instantiate() as RigidBody3D
	var over := (load(CRATE) as PackedScene).instantiate() as RigidBody3D
	var beside := (load(CRATE) as PackedScene).instantiate() as RigidBody3D
	var floor_y: float = truck._bed_floor_local_y()
	var mid: Vector3 = truck._bed_floor.get_center()
	var places: Array = [[under, Vector3(mid.x, floor_y + 0.25, mid.z)], [over, Vector3(mid.x + 0.1, floor_y + 0.75, mid.z)],
			[beside, Vector3(mid.x - 0.6, floor_y + 0.25, mid.z)]]
	for placed: Array in places:
		add_child_autofree(placed[0])
		(placed[0] as Node).add_to_group("carriable")
		(placed[0] as Node3D).global_position = truck.to_global(placed[1])
		assert_true(truck.lock_resting_cargo(placed[0]))
	truck.release_cargo(under)
	assert_false(truck._locked_cargo.has(over), "what lay on it falls")
	assert_false(over.freeze, "back to physics")
	assert_true(truck._locked_cargo.has(beside), "its neighbour stays")
