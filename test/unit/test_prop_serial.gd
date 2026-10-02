extends GutTest
## PropSerial: the "COMPANY-TYPE-UUID" serial and its frames, shared by the crates (GenericProp) and
## the vehicles' plates (Vehicle). The truck's plate is filled the moment its uuid arrives — which on
## a client is before it enters the tree.

const UUID : String = "8c44b2f9-1d2e-4a5b-9c6d-7e8f9a0b1c2d"
const TRUCK : String = "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"


func test_the_serial_in_full_and_short() -> void:
	assert_eq(PropSerial.format("ARES", "HAUL", UUID, false), "ARES-HAUL-" + UUID)
	assert_eq(PropSerial.format("ARES", "HAUL", UUID, true), "ARES-HAUL-8C44B2F9", "first block, uppercased")
	assert_eq(PropSerial.format("ARES", "HAUL", "", true), "", "nothing before the uuid")


func test_fill_writes_the_frames_only() -> void:
	var root := Node3D.new()
	var frame := Label3D.new()
	frame.add_to_group(PropSerial.LABEL_GROUP)
	var other := Label3D.new()
	other.text = "kept"
	root.add_child(frame)
	root.add_child(other)
	PropSerial.fill(root, "ARES-HAUL-8C44B2F9")
	assert_eq(frame.text, "ARES-HAUL-8C44B2F9", "a frame, by its group")
	assert_eq(other.text, "kept", "another label is left alone")
	PropSerial.fill(root, "")
	assert_eq(frame.text, "ARES-HAUL-8C44B2F9", "an empty serial changes nothing")
	root.free()


func test_the_truck_plate_shows_its_registration() -> void:
	var truck : Vehicle = (load(TRUCK) as PackedScene).instantiate()
	var plates : Array[Label3D] = []
	for node in truck.find_children("*", "Label3D", true, false):
		if node.is_in_group(PropSerial.LABEL_GROUP):
			plates.append(node)
	assert_gt(plates.size(), 0, "the truck has a plate")
	truck.uuid = UUID  # what the client does, before add_child
	for plate in plates:
		assert_eq(plate.text, "ARES-TRUCK-8C44B2F9", "%s carries the registration" % plate.name)
	truck.free()
