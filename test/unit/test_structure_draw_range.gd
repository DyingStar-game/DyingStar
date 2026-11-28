extends GutTest
## StructureDrawRange: a part of a building is drawn as far as its size is worth a few pixels, what it
## cannot measure as far as the building, and a deliberate range is left alone.


func _mesh(size: Vector3) -> MeshInstance3D:
	var m: MeshInstance3D = autofree(MeshInstance3D.new())
	var box := BoxMesh.new()
	box.size = size
	m.mesh = box
	return m


func test_a_part_goes_at_a_distance_of_its_size() -> void:
	assert_almost_eq(StructureDrawRange.part_end_m(_mesh(Vector3(4.0, 1.0, 1.0))), 400.0, 0.01)


func test_a_small_part_stays_across_a_street() -> void:
	assert_eq(StructureDrawRange.part_end_m(_mesh(Vector3.ONE * 0.1)), StructureDrawRange.PART_MIN_M)


func test_a_whole_building_keeps_the_far_cap() -> void:
	assert_eq(StructureDrawRange.part_end_m(_mesh(Vector3.ONE * 500.0)), StructureDrawRange.FAR_M)


func test_the_scale_of_a_part_counts() -> void:
	var m := _mesh(Vector3.ONE)
	m.scale = Vector3(1.0, 8.0, 1.0)
	assert_almost_eq(StructureDrawRange.part_end_m(m), 800.0, 0.01)


func test_a_csg_box_is_measured_before_its_mesh_is_built() -> void:
	var box: CSGBox3D = autofree(CSGBox3D.new())
	box.size = Vector3(2.0, 3.0, 1.0)
	assert_almost_eq(StructureDrawRange.part_end_m(box), 300.0, 0.01)


func test_what_cannot_be_measured_keeps_the_far_cap() -> void:
	var combiner: CSGCombiner3D = autofree(CSGCombiner3D.new())
	assert_eq(StructureDrawRange.part_end_m(combiner), StructureDrawRange.FAR_M)


func test_the_far_level_of_a_lod_chain_keeps_the_far_cap() -> void:
	var m := _mesh(Vector3.ONE)
	m.visibility_range_begin = 50.0
	assert_eq(StructureDrawRange.part_end_m(m), StructureDrawRange.FAR_M)


func test_a_deliberate_range_is_left_alone() -> void:
	var m := _mesh(Vector3.ONE)
	m.visibility_range_end = 25.0
	StructureDrawRange._track(m)
	assert_eq(m.visibility_range_end, 25.0)


## A building whose apartments and walkways arrive after it (a scene under structures/: is_building).
func _building() -> Node3D:
	var b := Node3D.new()
	b.scene_file_path = "res://scenes/_universe/structures/buildings/a_building.tscn"
	StructureDrawRange.attach_to(b)
	add_child_autofree(b)
	return b


func test_what_enters_a_building_later_is_covered_at_every_depth() -> void:
	var b := _building()
	var apartment := Node3D.new()
	var room := Node3D.new()
	var lamp := _mesh(Vector3.ONE * 0.5)
	apartment.add_child(room)
	room.add_child(lamp)
	b.add_child(apartment)
	assert_true(DrawRange.is_tracked(lamp), "a mesh two levels down is tracked")
	for node: Node in [apartment, room, lamp]:
		assert_true(node.child_entered_tree.is_connected(StructureDrawRange._cover), "%s listens" % node.name)


func test_what_a_covered_node_gains_afterwards_is_covered() -> void:
	var b := _building()
	var apartment := Node3D.new()
	b.add_child(apartment)
	var interior := Node3D.new()
	var chair := _mesh(Vector3.ONE * 0.5)
	interior.add_child(chair)
	apartment.add_child(interior)  # the interior streamed in near the camera
	assert_true(DrawRange.is_tracked(chair))
	assert_almost_eq(chair.visibility_range_end,
			StructureDrawRange.PART_MIN_M * DrawRange.multiplier(StructureDrawRange.OPTION), 0.01)
