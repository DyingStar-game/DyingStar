extends GutTest

## The miners' tools are handed out at the changing rooms ("la salle des pendus"), not at the cargo depot
## any more; and money earned chimes once where the other notifications beep until read.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_changing_rooms_tools.gd

const CHANGING_ROOMS := "res://scenes/_universe/structures/industrial/mines/changing_rooms.tscn"
const CARGO_DEPOT := "res://scenes/_universe/structures/industrial/cargo_depot.tscn"


func _tool_dispensers(scene_path: String) -> Array:
	var scene: Node = (load(scene_path) as PackedScene).instantiate()
	autofree(scene)
	return scene.find_children("*", "ToolDispenser", true, false)


func test_the_tool_dispensers_stand_in_the_changing_rooms_open_room() -> void:
	var dispensers := _tool_dispensers(CHANGING_ROOMS)
	assert_eq(dispensers.size(), 2)
	var building: Node3D = (dispensers[0] as Node3D).get_parent()
	var shell := building.get_node("Blockout") as CSGBox3D
	var room := shell.get_node("Room") as CSGBox3D
	var doorway := shell.get_node("Doorway") as CSGBox3D
	for hole: CSGBox3D in [room, doorway]:
		assert_eq(hole.operation, CSGShape3D.OPERATION_SUBTRACTION, "%s is cut out of the building" % hole.name)
	# The doorway goes through the front wall, from outside into the room.
	var front: float = -shell.size.z * 0.5
	assert_lt(doorway.position.z - doorway.size.z * 0.5, front, "open on the outside")
	assert_gt(doorway.position.z + doorway.size.z * 0.5, room.position.z - room.size.z * 0.5, "and on the room")
	assert_almost_eq(doorway.position.y - doorway.size.y * 0.5, room.position.y - room.size.y * 0.5, 0.001,
			"no sill to step over")
	for dispenser: Node3D in dispensers:
		var at: Vector3 = dispenser.position - (shell.position + room.position)
		assert_true(absf(at.x) < room.size.x * 0.5 and absf(at.z) < room.size.z * 0.5,
				"%s stands inside the room" % dispenser.name)
		assert_almost_eq(dispenser.position.y, shell.position.y + room.position.y - room.size.y * 0.5, 0.001,
				"on its floor")
		assert_almost_eq(dispenser.basis.z.z, -1.0, 0.001, "facing the door")
	KnownEngineErrors.forgive_floor_material(self)


func test_the_cargo_depot_hands_out_no_tool() -> void:
	assert_eq(_tool_dispensers(CARGO_DEPOT).size(), 0)
	KnownEngineErrors.forgive_floor_material(self)


func test_the_prompt_of_a_player_without_a_tool_names_the_building() -> void:
	for locale: String in ["en", "fr"]:
		var text: String = TranslationServer.get_translation_object(locale).get_message("%%HUD_NO_MINING_TOOL")
		assert_eq(text.count("%s"), 1, "%s: the building's name goes in" % locale)


func test_money_earned_chimes_and_the_rest_beeps() -> void:
	assert_true(ChatNetwork.is_gain("mission.completed"), "a mission paid")
	assert_true(ChatNetwork.is_gain("warehouse.sale"), "goods sold")
	assert_false(ChatNetwork.is_gain("mission.invited"))
	assert_false(ChatNetwork.is_gain("friend_request"))
	assert_false(ChatNetwork.is_gain(""))
