extends GutTest
## WarehouseDelivery, the team's crate rule (2026-11-06): a crate stays its creator's; a player
## deposits only their own crates or a mission partner's; who deposits is the player who put it
## down, the storekeeper acting for them. And the pieces around it: who holds a crate's goods, the
## key of a move (the same however often it is reported), the Refinery's empty crate, and the
## DataPad tab that blinks until its app is opened.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_warehouse_delivery.gd -gexit


## A player as WarehouseDelivery reads one: an id, and whether it is a storekeeper.
class PlayerDouble extends Node:
	var client_uuid := ""
	var is_npc := false


## A crate as WarehouseDelivery reads one: its content.
class CrateDouble extends Node3D:
	var content: Dictionary = {}


func _player(id: String, npc := false) -> PlayerDouble:
	var p := PlayerDouble.new()
	p.client_uuid = id
	p.is_npc = npc
	add_child_autofree(p)
	return p


func _crate(miner: String) -> CrateDouble:
	var c := CrateDouble.new()
	c.content = CrateContent.crushed("gold", 0.02, 0.04, 108.0, miner, miner)
	add_child_autofree(c)
	return c


func test_the_depositor_is_the_player_or_who_put_it_down_for_a_storekeeper() -> void:
	var crate := _crate("kira")
	WarehouseDelivery.note_dropped_by(crate, _player("kira"))
	assert_eq(WarehouseDelivery.depositor_of(crate, _player("orin")), "orin", "a player shelving it deposits it")
	assert_eq(WarehouseDelivery.depositor_of(crate, _player("npc-1", true)), "kira",
		"the storekeeper acts for whoever put it on the counter")
	WarehouseDelivery.note_dropped_by(crate, _player("npc-1", true))
	assert_eq(WarehouseDelivery.depositor_of(crate, null), "kira", "a storekeeper's drop changes nothing")


func test_own_unowned_or_unknown_crates_need_no_question() -> void:
	assert_true(WarehouseDelivery.owns_or_unknown("kira", "kira"), "their own")
	assert_true(WarehouseDelivery.owns_or_unknown("", "kira"), "nobody's (the admin fill)")
	assert_true(WarehouseDelivery.owns_or_unknown("kira", ""), "nobody known (on the counter at boot)")
	assert_false(WarehouseDelivery.owns_or_unknown("kira", "orin"), "somebody else's: is Orin her partner?")


func test_a_known_answer_is_not_asked_again() -> void:
	var crate := _crate("kira")
	crate.set_meta(WarehouseDelivery.DEPOSIT_OK_META, {"orin": false})
	assert_false(await WarehouseDelivery.may_deposit(crate, "orin"))
	assert_true(await WarehouseDelivery.may_deposit(crate, "kira"))


func test_the_goods_follow_the_last_loader_else_the_miner() -> void:
	var content := CrateContent.crushed("gold", 0.02, 0.04, 108.0, "kira", "kira")
	assert_eq(CrateContent.holder_of(content), "kira")
	content["carrier_id"] = "orin"
	assert_eq(CrateContent.holder_of(content), "orin")


func test_a_move_key_is_the_same_until_the_crate_moves_again() -> void:
	var content := {"move_seq": 2}
	var key := WarehouseDelivery.move_key(content, "crate-1", "drop", "depot-a")
	assert_eq(WarehouseDelivery.move_key(content, "crate-1", "drop", "depot-a"), key, "a repeated report dedups")
	content["move_seq"] = 3
	assert_ne(WarehouseDelivery.move_key(content, "crate-1", "drop", "depot-a"), key, "the next real move counts")


func test_a_shelf_outside_a_cargo_depot_is_no_warehouse() -> void:
	var shelf := Node3D.new()
	add_child_autofree(shelf)
	assert_eq(WarehouseDelivery.depot_uuid_of(shelf), "")
	assert_eq(WarehouseDelivery.depot_uuid_of(null), "")


func test_an_empty_crate_is_still_a_crate_the_refinery_refuses() -> void:
	var crate: Node = load("res://scenes/_universe/props/containers/hauling_box.tscn").instantiate()
	add_child_autofree(crate)
	assert_true(Refinery.is_crate(crate), "told by its network type, not by its content")
	assert_true(Refinery.crate_content_of(crate).is_empty())
	assert_false(CrateContent.is_crushed(Refinery.crate_content_of(crate)), "nothing to refine: refused")
	var rock := Node3D.new()
	add_child_autofree(rock)
	assert_false(Refinery.is_crate(rock))


func test_the_refinery_consumes_into_its_own_system_holder() -> void:
	assert_eq(Refinery.consumed_holder("r-1"), {"holderType": "system", "holderId": "r-1"})


func test_a_flagged_app_blinks_until_it_is_opened() -> void:
	var terminal := TerminalUI.new()
	add_child_autofree(terminal)
	terminal.flag_app("missions")
	assert_true(terminal.has_pending())
	terminal.flag_app("")
	assert_true(terminal.has_pending(), "nothing to flag changes nothing")


func test_a_shelved_crate_is_taken_only_by_whom_it_is_kept_for() -> void:
	var crate := _crate("kira")
	var stranger := _player("orin")
	assert_true(WarehouseDelivery.may_take(crate, stranger), "not shelved: anybody carries it")
	crate.content["delivered_to"] = "depot-1"
	assert_false(WarehouseDelivery.may_take(crate, stranger), "shelved: the warehouse's")
	assert_false(WarehouseDelivery.may_take(crate, _player("kira")), "even for its miner")
	assert_true(WarehouseDelivery.may_take(crate, _player("npc", true)), "a storekeeper tidies it")
	crate.content["reserved_for"] = {"mission": "m1", "name": "player-orin", "ids": ["orin"]}
	assert_true(WarehouseDelivery.may_take(crate, stranger), "kept for orin's transport")


func test_a_warehouse_of_the_federation_is_ares() -> void:
	var ares := WarehouseOwner.owner_from_poi({"ownerType": "political", "ownerId": "fed-1"})
	assert_eq(ares["name"], CrateContent.OWNER_ARES)
	assert_eq(ares["type"], "political")
	assert_eq(WarehouseOwner.plate_owner({"name": "ARES CORP.", "village": "M0001"}), "ARES CORP. · M0001",
			"the owner, and the village whose warehouse holds it")
	assert_eq(WarehouseOwner.plate_owner({"name": "ARES CORP."}), "ARES CORP.")


func test_a_transport_out_of_a_warehouse_asks_for_its_crates() -> void:
	var detail := {
		"objectives": [{"type": "transport", "status": "in_progress", "targetQuantity": 90, "currentProgress": 40,
			"locationFrom": {"warehouseId": "depot-M"},
			"params": {"via": "warehouse", "goodType": "ore.gold", "deliverGoodType": "ingot.gold"}}],
		"assignments": [{"playerId": "kira", "status": "active"}, {"playerId": "orin", "status": "active"}],
		"players": {"kira": "player-kira"},
	}
	var need: Dictionary = await TransportReservations.need_of(detail)
	assert_eq(need["depot"], "depot-M")
	assert_eq(need["good"], "ore.gold")
	assert_eq(need["kg"], 50.0, "what is left to deliver")
	assert_eq(need["ids"], ["kira", "orin"], "the taker and their partner")
	assert_eq(need["name"], "player-kira")
	detail["objectives"][0]["params"]["via"] = "zone"
	assert_true((await TransportReservations.need_of(detail)).is_empty(), "not loaded from a warehouse")


func test_shelves_are_lettered_by_aisle_and_numbered_along_it() -> void:
	var at := func(n: String, x: float, z: float, yaw: float) -> Dictionary:
		return {"name": n, "position": {"x": x, "y": 0.0, "z": z}, "rotation": {"x": 0.0, "y": yaw, "z": 0.0}}
	var labels := ShelfLabels.labels_for([
		at.call("wall", -7.6, 0.0, PI), at.call("l1", -6.8, 0.0, 0.0), at.call("l2", -6.8, 1.0, 0.0),
		at.call("r1", -3.6, 0.0, PI), at.call("shelf_cargo_temp_zone", -5.4, 8.0, 0.0)])
	assert_eq(labels["wall"], "A01", "a row against the wall is an aisle of its own")
	assert_eq(labels["l1"], "B01", "across the walk: one aisle, the left row first")
	assert_eq(labels["r1"], "B02")
	assert_eq(labels["l2"], "B03", "then along it")
	assert_false(labels.has("shelf_cargo_temp_zone"), "the buffer rack has no label")
	assert_eq(ShelfLabels.label_of("shelf_cargo_row1_1").length(), 3, "the depot's own layout is labelled")


func test_the_depot_board_says_who_collects_what_where() -> void:
	var shelf := Node3D.new()
	shelf.name = "shelf_cargo_row1_1"
	add_child_autofree(shelf)
	var crates: Array = []
	for i: int in range(3):
		var crate := CrateDouble.new()
		crate.content = CrateContent.crushed("gold", 0.02, 0.04, 108.0, "kira", "kira")
		if i < 2:
			crate.content["reserved_for"] = {"mission": "m1", "name": "player-orin", "ids": ["orin"]}
		shelf.add_child(crate)
		crates.append(crate)
	var text := PickupBoard.board_text(crates)
	assert_string_contains(text, "player-orin  ·  %s  ·  2 × " % ShelfLabels.label_of("shelf_cargo_row1_1"))
	assert_eq(text.count("\n"), 1, "the title and one line: the third crate is kept for nobody")


func test_the_stock_board_lists_each_good_its_crates_kg_and_shelves() -> void:
	var shelf := Node3D.new()
	shelf.name = "shelf_cargo_row1_1"
	add_child_autofree(shelf)
	var crates: Array = []
	for i: int in range(3):
		var crate := CrateDouble.new()
		var crushed := CrateContent.crushed("gold", 0.02, 0.04, 108.0, "kira", "kira")
		crate.content = CrateContent.refined(crushed) if i == 0 else crushed
		shelf.add_child(crate)
		crates.append(crate)
	var lines := StockBoard.stock_lines(crates)
	assert_eq(lines.size(), 4, "two goods, each with its shelves under it")
	var kg := int((crates[1] as CrateDouble).content["units"]) * 2
	assert_string_contains(" | ".join(lines), "%d kg" % kg, "the crushed ore's two crates summed")
	assert_string_contains(lines[1], ShelfLabels.label_of("shelf_cargo_row1_1"), "where it is")
	assert_eq(StockBoard.stock_lines([]).size(), 1, "an empty warehouse says so")


func test_the_stock_board_scrolls_a_long_list_round() -> void:
	var lines := PackedStringArray(["a", "b", "c"])
	assert_eq(StockBoard.window(lines, 5, 4), lines, "it fits: all of it, no scrolling")
	assert_eq(StockBoard.window(lines, 0, 2), PackedStringArray(["a", "b"]))
	assert_eq(StockBoard.window(lines, 2, 2), PackedStringArray(["c", ""]), "a blank line before it starts over")
	assert_eq(StockBoard.window(lines, 3, 2), PackedStringArray(["", "a"]))


func test_a_shelf_is_labelled_by_where_it_stands_when_its_name_is_late() -> void:
	var shelf := Node3D.new()
	add_child_autofree(shelf)
	shelf.position = Vector3(-7.643, 0.0, 13.0)  # shelf_cargo_row1_1 in the depot's layout
	assert_eq(ShelfLabels.label_for(shelf), ShelfLabels.label_of("shelf_cargo_row1_1"), "by its place")
	shelf.position = Vector3(40.0, 0.0, 40.0)
	assert_eq(ShelfLabels.label_for(shelf), "", "a shelf outside the depot's rows has none")


func test_each_aisle_has_its_sign_at_its_mouth() -> void:
	var at := func(n: String, x: float, z: float, yaw: float) -> Dictionary:
		return {"name": n, "position": {"x": x, "y": 0.0, "z": z}, "rotation": {"x": 0.0, "y": yaw, "z": 0.0}}
	var signs := ShelfLabels.aisle_signs_for([at.call("wall", -7.6, 13.0, PI), at.call("l1", -6.8, 13.0, 0.0),
		at.call("l2", -6.8, 14.0, 0.0), at.call("r1", -3.6, 13.0, PI)])
	assert_eq(signs.size(), 2)
	assert_eq(signs[1][0], "B")
	assert_almost_eq((signs[1][1] as Vector3).x, -5.2, 0.001, "in the middle of the walk")
	assert_almost_eq((signs[1][1] as Vector3).z, 12.0, 0.001, "before its first shelf")
	assert_eq(ShelfLabels.aisle_signs().size(), 5, "the depot's five aisles")


func test_floor_paint_lies_flat_its_top_where_asked() -> void:
	var basis := FloorPaint.flat(PI / 2.0)
	assert_almost_eq(basis.z, Vector3.UP, Vector3.ONE * 0.001, "facing up")
	assert_almost_eq(basis.y, Vector3(-1, 0, 0), Vector3.ONE * 0.001, "its text's top toward -X")
	assert_almost_eq(FloorPaint.flat(PI).y, Vector3(0, 0, 1), Vector3.ONE * 0.001, "into an aisle")
