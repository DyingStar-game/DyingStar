extends GutTest
## Furniture of a home: doors and drawers (MovingPart) move their leaf about its hinge or along its
## slide, the building keeps which parts are on (SpawnBuilding.furniture), and a home is its occupant's:
## only they use its furniture or put a load down in it.

const BUILDING := "res://scenes/_universe/structures/buildings/spawn_building.tscn"


func test_a_door_turns_about_its_hinge() -> void:
	var rest := Transform3D(Basis.IDENTITY, Vector3(1.0, 0.0, 2.0))
	var open: Transform3D = MovingPart.pose(rest, Vector3.UP, 90.0, Vector3.ZERO, 1.0)
	assert_almost_eq(open.origin, rest.origin, Vector3.ONE * 1e-6, "the hinge stays put")
	assert_almost_eq(open.basis * Vector3(0.0, 0.0, 1.0), Vector3(1.0, 0.0, 0.0), Vector3.ONE * 1e-6)
	var half: Transform3D = MovingPart.pose(rest, Vector3.UP, 90.0, Vector3.ZERO, 0.5)
	assert_almost_eq(half.basis.get_euler().y, deg_to_rad(45.0), 1e-6, "half-way, half the angle")
	assert_eq(MovingPart.pose(rest, Vector3.UP, 90.0, Vector3.ZERO, 0.0), rest, "shut: its rest pose")


func test_a_drawer_slides_in_its_own_frame() -> void:
	var rest := Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, 0.5, 0.0))
	var open: Transform3D = MovingPart.pose(rest, Vector3.UP, 0.0, Vector3(0.3, 0.0, 0.0), 1.0)
	assert_almost_eq(open.origin, Vector3(-0.3, 0.5, 0.0), Vector3.ONE * 1e-6, "turned drawers pull the other way")
	assert_eq(open.basis, rest.basis)


func test_a_shown_part_moves_its_leaf() -> void:
	var leaf := Node3D.new()
	var part := MovingPart.new()
	part.open_angle_deg = -90.0
	part.label_off = "%%HUD_DOOR_OPEN"
	part.label_on = "%%HUD_DOOR_CLOSE"
	leaf.add_child(part)
	add_child_autofree(leaf)
	part.show_state(true, false)
	assert_almost_eq(leaf.rotation.y, deg_to_rad(-90.0), 1e-6, "at once when not animated")
	assert_eq(part.label, "%%HUD_DOOR_CLOSE", "the prompt says what the key will do now")
	part.show_state(false, false)
	assert_almost_eq(leaf.rotation.y, 0.0, 1e-6)
	assert_eq(part.label, "%%HUD_DOOR_OPEN")


func test_a_lamp_lights_its_lights() -> void:
	var lamp := LightSwitch.new()
	var light := OmniLight3D.new()
	lamp.add_child(light)
	add_child_autofree(lamp)
	lamp.show_state(true, false)
	assert_true(light.visible)
	lamp.show_state(false, false)
	assert_false(light.visible)


func test_the_state_lists_the_parts_on() -> void:
	var state := {"0-0-0/DoorL": true}
	var opened: Dictionary = SpawnBuilding.furniture_toggled(state, "0-1-0/Lamp")
	assert_eq(opened, {"0-0-0/DoorL": true, "0-1-0/Lamp": true})
	assert_eq(SpawnBuilding.furniture_toggled(opened, "0-0-0/DoorL"), {"0-1-0/Lamp": true}, "off: dropped")
	assert_eq(state, {"0-0-0/DoorL": true}, "a new state, the old one untouched (it is compared)")


func test_a_home_is_its_occupant_s() -> void:
	var building := (load(BUILDING) as PackedScene).instantiate() as SpawnBuilding
	building.cols = 2
	building.apartments = [{"floor": 0, "row": 0, "col": 1, "player_uuid": "abc", "player_name": "Ann"}]
	PropSync.of(building).uuid = "home-uuid"
	building._create_apartments()
	var rooms: Node = building.get_node("MultiMeshInstance3D")
	var bed_there: Node = rooms.get_node("0-1-0").find_child("Bed", true, false)
	var bed_free: Node = rooms.get_node("0-0-0").find_child("Bed", true, false)
	assert_false(SpawnBuilding.is_foreign_home(bed_there, "abc"), "their own")
	assert_true(SpawnBuilding.is_foreign_home(bed_there, "xyz"), "a neighbour's")
	assert_true(SpawnBuilding.is_foreign_home(bed_free, "abc"), "a free one is nobody's")
	assert_false(SpawnBuilding.is_foreign_home(null, "abc"), "the ground outside")
	building.free()


func test_the_building_shows_its_state() -> void:
	var building := (load(BUILDING) as PackedScene).instantiate() as SpawnBuilding
	building.cols = 2
	PropSync.of(building).uuid = "home-uuid"
	add_child_autofree(building)
	var key := "0-1-0/habitat_container/frame/left_door/DoorL"
	building.apply_prop_data({"apartments": [], "furniture": {key: true}})
	var rooms: Node = building.get_node("MultiMeshInstance3D")
	var there := rooms.get_node("0-1-0/habitat_container/frame/left_door/DoorL") as MovingPart
	var here := rooms.get_node("0-0-0/habitat_container/frame/left_door/DoorL") as MovingPart
	assert_eq(there.state_key(), key)
	assert_true(there.is_on, "listed: open")
	assert_false(here.is_on, "not listed: shut")
	assert_almost_eq((there.get_parent() as Node3D).rotation.y, deg_to_rad(-90.0), 1e-4, "open at once on arrival")
	building.apply_prop_data({"furniture": {}})
	assert_false(there.is_on, "closed by a later change")
	var lamps: Array = rooms.find_children("Lamp", "Area3D", true, false)
	assert_eq(lamps.size(), 2, "a lamp in every apartment")
	_forgive_floor_material()


## The spawn building's pad pulls in concrete_floor_001.tres, whose triplanar + height mapping raises an
## engine error the first time it loads (see test_terrain_pad): not this test's.
func _forgive_floor_material() -> void:
	for e in get_errors():
		if (str(e.code) + str(e.rationale)).contains("Height mapping"):
			e.handled = true
