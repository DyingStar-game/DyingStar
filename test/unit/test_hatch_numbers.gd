extends GutTest
## Each component bay's number, on its hatch and beside its box on the dashboard: the n-th bay of
## VehicleComponentBays.all(), so a part goes where it is read.

const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"


func test_the_number_sits_on_the_outer_face_upright_at_unit_scale() -> void:
	# The truck's front-left hatch: a mesh scaled (0.175, 0.225, 0.325), its box thin along x, on the left.
	var in_vehicle := Transform3D(Basis.from_scale(Vector3(0.175, 0.225, 0.325)), Vector3(-0.85, 0.18, -0.28))
	var aabb := AABB(Vector3(-0.257, -1.0, 0.0), Vector3(0.257, 2.0, 2.0))
	var label: Transform3D = in_vehicle * HatchNumbers.placement(in_vehicle, aabb)
	assert_almost_eq(label.basis.z.normalized(), Vector3.LEFT, Vector3.ONE * 1e-5, "facing out, to the left")
	assert_almost_eq(label.basis.y.normalized(), Vector3.UP, Vector3.ONE * 1e-5, "upright")
	assert_almost_eq(label.basis.get_scale(), Vector3.ONE, Vector3.ONE * 1e-5, "the mesh's scale undone")
	assert_lt(label.origin.x, -0.85 - 0.257 * 0.175, "on the outer face, a little off it")
	assert_almost_eq(label.origin.z, -0.28 + 0.325, 1e-5, "in its middle")
	var right := Transform3D(Basis.from_scale(Vector3(0.175, 0.225, 0.325)), Vector3(0.85, 0.18, -0.28))
	var on_right: Transform3D = right * HatchNumbers.placement(right, AABB(Vector3(0.0, -1.0, 0.0), Vector3(0.257, 2.0, 2.0)))
	assert_almost_eq(on_right.basis.z.normalized(), Vector3.RIGHT, Vector3.ONE * 1e-5, "the right side: to the right")


func test_each_hatch_of_the_truck_bears_its_bay_s_number() -> void:
	# A truck as a client has it: its own start numbers its hatches.
	var truck := (load(TRUCK) as PackedScene).instantiate() as Vehicle
	add_child_autofree(truck)
	await get_tree().process_frame
	var slots: Array = truck.bays.all()
	assert_eq(slots.size(), 4, "four bays")
	for i in slots.size():
		var hatch: Node = truck._door_mesh(str(slots[i].door_id))
		assert_not_null(hatch, "%s has a mesh" % slots[i].door_id)
		var label := hatch.get_node_or_null(HatchNumbers.NAME) as Label3D
		assert_not_null(label, "%s is numbered" % slots[i].door_id)
		assert_eq(label.text, str(i + 1), "%s: the dashboard's number" % slots[i].door_id)
	HatchNumbers.paint(truck, slots, truck._door_mesh)
	assert_eq(truck._door_mesh(str(slots[0].door_id)).get_children().filter(
			func(n: Node) -> bool: return n is Label3D).size(), 1, "painted once")


func test_the_dashboard_shows_each_bay_s_number_beside_its_box() -> void:
	var row: HBoxContainer = VehicleDashboard._bay_box(3)
	assert_eq((row.get_child(0) as Label).text, "3", "its number first")
	assert_true(row.get_child(1) is PanelContainer, "then its box")
	VehicleDashboard._show_bay(row, load(VehicleDashboard.ICON_DIR + "motor.png"))
	assert_eq(((row.get_child(1) as PanelContainer).get_child(0) as TextureRect).modulate,
			VehicleDashboard.bay_colour(true), "fitted: green")
	row.free()
