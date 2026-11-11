extends GutTest

## Off-mission sales (services ADR 0016): what a player shelves of their own goods that no mission of
## theirs counted is sold to the federation, and they are told; a transport's load or a mission's crate
## is never sold.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_warehouse_sale.gd


func test_only_the_players_own_goods_are_sold() -> void:
	var mined := CrateContent.crushed("gold", 0.02, 0.04, 108.0, "kira", "kira")
	assert_true(WarehouseDelivery.is_sellable(mined), "mined by them")
	var loaded := mined.duplicate()
	loaded["carrier_id"] = "kira"
	assert_false(WarehouseDelivery.is_sellable(loaded), "taken off a warehouse's shelf: no sale")
	var kept := mined.duplicate()
	kept["for_mission"] = {"id": "m1"}
	assert_false(WarehouseDelivery.is_sellable(kept), "a mission's crate: no sale")
	assert_false(WarehouseDelivery.is_sellable(CrateContent.crushed("gold", 0.02, 0.04, 108.0, "", "")),
			"nobody's (the admin fill): no sale")


func test_what_the_missions_did_not_count_is_sold() -> void:
	assert_eq(MissionHeartbeat.sale_quantity(20, 0), 20, "no mission: all of it")
	assert_eq(MissionHeartbeat.sale_quantity(20, 12), 8, "the rest")
	assert_eq(MissionHeartbeat.sale_quantity(20, 20), 0, "all counted: nothing")
	assert_eq(MissionHeartbeat.sale_quantity(20, -1), 0, "no answer: nothing on a guess")


func test_a_keyed_call_is_tried_again_only_when_another_try_may_pass() -> void:
	assert_true(MissionHeartbeat.worth_retrying({"ok": false, "status": 0}), "not reached")
	assert_true(MissionHeartbeat.worth_retrying({"ok": false, "status": 502, "error": "UPSTREAM_ERROR"}))
	assert_true(MissionHeartbeat.worth_retrying({"ok": false, "status": 409, "error": "SALE_IN_PROGRESS"}))
	assert_false(MissionHeartbeat.worth_retrying({"ok": false, "status": 409, "error": "IDEMPOTENCY_CONFLICT"}))
	assert_false(MissionHeartbeat.worth_retrying({"ok": false, "status": 404, "error": "NOT_FOUND"}), "refused: again too")


func test_a_sale_reads_in_the_players_language() -> void:
	var line := ChatNetwork.sale_text({"village": "M0001", "name": "Crushed gold ore", "nameFr": "Minerai d'or concassé",
			"quantity": 120, "unit": "kg", "amount": 1500, "currency": "credits"})
	assert_string_contains(line, "M0001")
	assert_string_contains(line, "120 kg")
	assert_string_contains(line, "1500")
	assert_eq(ServiceTypes.transaction_sale_village({"reference": "sale:M0001:ore.gold"}), "M0001")
	assert_eq(ServiceTypes.transaction_sale_village({"reference": "mission:abc"}), "")
