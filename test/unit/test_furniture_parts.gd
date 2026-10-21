extends GutTest
## Furniture of a home: doors and drawers (MovingPart) move their leaf about its hinge or along its
## slide, the building keeps which parts are on (SpawnBuilding.furniture), and a home is its occupant's:
## only they use its furniture or put a load down in it.

const BUILDING := "res://scenes/_universe/structures/buildings/spawn_building.tscn"
const BED := "res://scenes/_universe/props/furniture/chamber/bed.tscn"


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


func test_the_state_keeps_what_was_set() -> void:
	var state := {"0-0-0/DoorL": true}
	var lit: Dictionary = FurnitureState.with_part(state, "0-1-0/Lamp", true)
	assert_eq(lit, {"0-0-0/DoorL": true, "0-1-0/Lamp": true})
	assert_eq(FurnitureState.with_part(lit, "0-0-0/DoorL", false), {"0-0-0/DoorL": false, "0-1-0/Lamp": true},
			"shut is kept too: a lamp switched off at night stays off")
	assert_eq(state, {"0-0-0/DoorL": true}, "a new state, the old one untouched (it is compared)")


func test_the_latch_turns_before_the_leaf() -> void:
	assert_eq(MovingPart.phases(0.15, 0.3), Vector2(0.5, 0.0), "the handle half up, the door still shut")
	assert_eq(MovingPart.phases(0.3, 0.3), Vector2(1.0, 0.0))
	assert_almost_eq(MovingPart.phases(0.65, 0.3), Vector2(1.0, 0.5), Vector2.ONE * 1e-6, "then the door")
	assert_eq(MovingPart.phases(0.4, 0.0), Vector2(0.4, 0.4), "no latch: the leaf alone")


func test_the_night_lights_a_lamp_nobody_switched() -> void:
	var lamp := LightSwitch.new()
	var light := OmniLight3D.new()
	lamp.add_child(light)
	add_child_autofree(lamp)
	lamp.show_unset()
	lamp.set_lit(true, false)
	assert_true(light.visible, "the photocell's first reading, at night: lit")
	lamp.show_state(false, false)
	assert_false(light.visible, "switched off")
	lamp.set_lit(true, false)
	assert_false(light.visible, "a first reading does not undo the switch")
	lamp.set_lit(true, true)
	assert_true(light.visible, "the next dusk does")
	assert_true(lamp.is_on, "and the prompt follows: E puts it out")


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
	assert_almost_eq((there.get_parent() as Node3D).rotation.y, deg_to_rad(there.open_angle_deg), 1e-4, "open at once on arrival")
	building.apply_prop_data({"furniture": {key: false}})
	assert_false(there.is_on, "closed by a later change")
	var lamps: Array = rooms.find_children("Lamp", "Area3D", true, false)
	assert_eq(lamps.size(), 2, "a lamp in every apartment")
	KnownEngineErrors.forgive_floor_material(self)


func test_a_body_lies_down_on_the_mattress() -> void:
	var bed := (load(BED) as PackedScene).instantiate() as Node3D
	add_child_autofree(bed)
	var spot := bed.get_node("BedSpot") as BedSpot
	var body: Transform3D = spot.lie_transform()
	assert_almost_eq(body.basis.y, Vector3.UP, Vector3.ONE * 1e-6, "upright: the lay clip lays it down")
	assert_almost_eq(body.origin.y, 0.47, 0.01, "on the mattress (0.47 m)")
	assert_almost_eq(-body.basis.z, Vector3.BACK, Vector3.ONE * 1e-6, "facing the foot of the bed")
	var stand: Transform3D = spot.stand_point.global_transform
	assert_almost_eq(stand.basis.y, Vector3.UP, Vector3.ONE * 1e-6, "up again, upright")
	assert_almost_eq(stand.origin.y, 0.0, 1e-6, "on the floor")


func test_a_state_that_arrives_before_the_building_is_placed_still_shows() -> void:
	var building := (load(BUILDING) as PackedScene).instantiate() as SpawnBuilding
	PropSync.of(building).uuid = "home-uuid"
	var key := "0-0-0/habitat_container/frame/right_door/DoorR"
	building.apply_prop_data({"apartments": [], "furniture": {key: true}})  # not in the tree yet, as on arrival
	add_child_autofree(building)
	var right := building.get_node("MultiMeshInstance3D/0-0-0/habitat_container/frame/right_door/DoorR") as MovingPart
	assert_true(right.is_on)
	assert_almost_eq((right.get_parent() as Node3D).rotation.y, deg_to_rad(right.open_angle_deg), 1e-4, "shown open once placed")
	KnownEngineErrors.forgive_floor_material(self)


func test_only_an_npc_s_door_is_opened() -> void:
	var building := (load(BUILDING) as PackedScene).instantiate() as SpawnBuilding
	building.cols = 2
	PropSync.of(building).uuid = "home-uuid"
	add_child_autofree(building)
	building.apply_prop_data({"apartments": [
		{"floor": 0, "row": 0, "col": 0, "player_uuid": "npc-1", "player_name": "Bob"},
		{"floor": 0, "row": 0, "col": 1, "player_uuid": "player-1", "player_name": "Ann"},
	]})
	building.server_open_for_npc("npc-1")
	var rooms: Node = building.get_node("MultiMeshInstance3D")
	var door := "habitat_container/frame/right_door/DoorR"
	assert_true((rooms.get_node("0-0-0/" + door) as MovingPart).is_on, "the NPC's home")
	assert_false((rooms.get_node("0-1-0/" + door) as MovingPart).is_on, "a player's: shut")
	assert_eq(building.furniture, {"0-0-0/" + door: true}, "kept, like any use")
	assert_eq(FurnitureState.npc_doors(rooms.get_node("0-0-0")).size(), 1, "one door opens for an NPC")
	KnownEngineErrors.forgive_floor_material(self)



## A 1 m door hanging at the origin, its leaf's body a board along +X; [param open_deg] about up.
func _door(open_deg: float) -> MovingPart:
	var leaf := Node3D.new()
	add_child_autofree(leaf)
	var body := StaticBody3D.new()
	var board := CollisionShape3D.new()
	board.shape = BoxShape3D.new()
	(board.shape as BoxShape3D).size = Vector3(1.0, 2.0, 0.05)
	board.position = Vector3(0.5, 0.0, 0.0)
	body.add_child(board)
	leaf.add_child(body)
	var part := MovingPart.new()
	part.open_angle_deg = open_deg
	leaf.add_child(part)
	return part


## A solid box of the world, [param size] at [param at].
func _wall(at: Vector3, size: Vector3) -> void:
	var wall := StaticBody3D.new()
	var box := CollisionShape3D.new()
	box.shape = BoxShape3D.new()
	(box.shape as BoxShape3D).size = size
	wall.add_child(box)
	wall.position = at
	add_child_autofree(wall)


func test_a_door_opens_all_the_way_when_nothing_is_in_its_way() -> void:
	assert_eq(_door(165.0).free_reach(), 1.0)


func test_a_door_stops_short_of_the_wall_it_would_cut_into() -> void:
	# A wall 15 cm behind the hinge: the board reaches it a little past 90 degrees.
	_wall(Vector3(-0.2, 0.0, -0.6), Vector3(0.1, 2.0, 1.0))
	var door := _door(165.0)
	var reached: float = door.free_reach() * 165.0
	assert_between(reached, 85.0, 99.0, "stops at the wall, not through it")
	door.show_state(true, false)
	assert_almost_eq(door.get_parent_node_3d().rotation_degrees.y, reached, 0.01, "and the leaf is shown there")


func test_what_touches_the_door_shut_does_not_stop_it() -> void:
	# The frame it hangs in: overlapping the shut board along its edge.
	_wall(Vector3(0.5, 0.0, 0.03), Vector3(1.2, 2.2, 0.02))
	assert_eq(_door(-90.0).free_reach(), 1.0, "swinging away from its frame: all the way")
