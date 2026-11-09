extends GutTest

## A crate kept for a transport, or taken for it, says MISSION on its plate until it is delivered, and the
## crates on their way count for the mission: no other crate is kept for what they already carry
## (playtest 2026-11-09: taking a crate added one on another shelf of the pickup board).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_mission_crates.gd


const CRATE_DOUBLE := preload("res://test/unit/fixtures/content_holder.gd")


func _crushed() -> Dictionary:
	return CrateContent.crushed("gold", 0.02, 0.04, 108.0, "kira", "kira")


func test_a_kept_or_carried_crate_names_its_mission() -> void:
	var kept := _crushed()
	kept["reserved_for"] = {"mission": "m1", "title": "Transport", "name": "orin", "ids": ["o"]}
	assert_eq(CrateContent.mission_of(kept), {"id": "m1", "title": "Transport", "name": "orin", "ids": ["o"]},
			"the players too: a crate put back is kept for them again")
	var carried := _crushed()
	carried["for_mission"] = {"id": "m2", "title": "Haul", "name": "kira"}
	assert_eq(str(CrateContent.mission_of(carried)["id"]), "m2")
	assert_eq(CrateContent.mission_of(_crushed()), {}, "a crate of nobody's mission")


func test_the_plate_of_a_mission_crate_says_mission_and_still_fits() -> void:
	var content := _crushed()
	content["for_mission"] = {"id": "m1", "title": "Transport 90 kg Gold ingots", "name": "orin"}
	var plate := CratePlate.build_layout(content)
	add_child_autofree(plate)
	var labels := plate.find_children("*", "Label", true, false)
	var texts := labels.map(func(l: Label) -> String: return l.text)
	assert_true(texts.has(TranslationServer.translate("%%PLATE_MISSION")), "the band, translated")
	assert_true(texts.has("Transport 90 kg Gold ingots"), "its title")
	assert_true(texts.any(func(s: String) -> bool: return s.ends_with("orin")), "whose load")
	await get_tree().process_frame
	assert_lte(plate.get_combined_minimum_size().y, float(CratePlate.PX), "still on the plate")


func test_a_mission_with_crates_on_their_way_keeps_no_more_for_them() -> void:
	var need := {"depot": "", "good": "ore.gold", "kg": CrateContent.metal_kg(_crushed()), "name": "orin",
			"ids": ["o"], "title": "T"}
	var crate := _shelved_crate()
	TransportReservations.apply(crate.get_parent().get_parent(), {"m1": need}, {"m1": true})
	assert_true((crate.get("content") as Dictionary).get("reserved_for") is Dictionary, "nothing on its way: kept")
	crate = _shelved_crate()
	TransportReservations.apply(crate.get_parent().get_parent(), {"m1": need}, {"m1": true}, {"m1": need["kg"]})
	assert_false((crate.get("content") as Dictionary).has("reserved_for"), "covered by what is on its way")


## A crate shelved in a depot of its own (no PropSync: the depot's uuid and the crate's mark are both "").
func _shelved_crate() -> Node:
	var depot := Node3D.new()
	add_child_autofree(depot)
	var shelf := Shelf.new()
	depot.add_child(shelf)
	var crate := Node3D.new()
	crate.set_script(CRATE_DOUBLE)
	var content := _crushed()
	content["delivered_to"] = ""
	crate.set("content", content)
	shelf.add_child(crate)
	return crate


func test_the_buffer_rack_is_named_and_kept_last() -> void:
	var depot := Node3D.new()
	add_child_autofree(depot)
	var crates: Array = []
	for shelf_name: String in ["shelf_cargo_temp_zone", "shelf_cargo_row1_1"]:
		var shelf := Shelf.new()
		shelf.name = shelf_name
		depot.add_child(shelf)
		var crate := Node3D.new()
		crate.set_script(CRATE_DOUBLE)
		var content := _crushed()
		content["delivered_to"] = ""
		crate.set("content", content)
		shelf.add_child(crate)
		crates.append(crate)
	var ordered := TransportReservations.crates_of(depot)
	assert_eq(ordered[0], crates[1], "an aisle's crate first")
	assert_eq(ordered[1], crates[0], "the buffer rack's last")
	assert_eq(PickupBoard.shelf_name(crates[0].get_parent()), TranslationServer.translate("%%DEPOT_BUFFER"),
			"the board names the buffer rack")
