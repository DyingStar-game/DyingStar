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
