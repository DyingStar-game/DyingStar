extends GutTest
## Each component bay's number, on its hatch and beside its box on the dashboard: the n-th bay of
## VehicleComponentBays.all(), so a part goes where it is read. On the hatch it is a HatchNumber Label3D
## placed in the vehicle's scene, under the hatch's mesh so it swings with it.

const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"
const NAME := "HatchNumber"


func test_each_hatch_of_the_truck_bears_its_bay_s_number_facing_out() -> void:
	var truck := (load(TRUCK) as PackedScene).instantiate() as Vehicle
	add_child_autofree(truck)
	await get_tree().process_frame
	var slots: Array = truck.bays.all()
	assert_eq(slots.size(), 4, "four bays")
	for i in slots.size():
		var id := str(slots[i].door_id)
		var hatch: Node3D = truck._door_mesh(id)
		assert_not_null(hatch, "%s has a mesh" % id)
		var label := hatch.get_node_or_null(NAME) as Label3D
		assert_not_null(label, "%s is numbered" % id)
		assert_eq(label.text, str(i + 1), "%s: the dashboard's number" % id)
		var in_truck: Transform3D = LocalFrame.of(label, truck)
		var side := signf(in_truck.origin.x)
		assert_almost_eq(in_truck.basis.z.normalized(), Vector3(side, 0.0, 0.0), Vector3.ONE * 1e-4,
				"%s: reads from outside" % id)
		assert_almost_eq(in_truck.basis.y.normalized(), Vector3.UP, Vector3.ONE * 1e-4, "%s: upright" % id)


func test_the_dashboard_shows_each_bay_s_number_beside_its_box() -> void:
	var row: HBoxContainer = VehicleDashboard._bay_box(3)
	assert_eq((row.get_child(0) as Label).text, "3", "its number first")
	assert_true(row.get_child(1) is PanelContainer, "then its box")
	VehicleDashboard._show_bay(row, load(VehicleDashboard.ICON_DIR + "motor.png"))
	assert_eq(((row.get_child(1) as PanelContainer).get_child(0) as TextureRect).modulate,
			VehicleDashboard.bay_colour(true), "fitted: green")
	row.free()
