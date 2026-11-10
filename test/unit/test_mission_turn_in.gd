extends GutTest
## Turning a mission in at a town hall kiosk: which assignment may be turned in, which warehouse the
## mission delivers to (whose village's town hall validates it), and what the kiosk shows of a mission
## in progress (each objective's progress, TURN IN once every required objective is done).
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_mission_turn_in.gd -gexit


func _objective(order: int, via: String, poi: String, status := "pending", bonus := false) -> Dictionary:
	return {"order": order, "status": status, "isBonus": bonus, "targetQuantity": 66,
		"params": {"via": via, "zone": {"kind": "poi", "poiId": poi}}}


func test_only_an_active_assignment_of_the_player_is_turned_in() -> void:
	var assignments := [{"playerId": "p1", "status": "completed"}, {"playerId": "p2", "status": "active"}]
	assert_false(MissionTurnIn.holds_assignment(assignments, "p1"), "already completed")
	assert_true(MissionTurnIn.holds_assignment(assignments, "p2"))
	assert_false(MissionTurnIn.holds_assignment(null, "p2"))


func test_the_delivery_warehouse_is_the_last_warehouse_objective() -> void:
	# Transport + refining: loaded at the mine, delivered at the factory — the factory's town hall.
	var objectives := [_objective(0, "warehouse", "mine-poi"), _objective(1, "warehouse", "factory-poi"),
		_objective(2, "zone", "elsewhere")]
	assert_eq(MissionTurnIn.delivery_poi(objectives), "factory-poi")
	assert_eq(MissionTurnIn.delivery_poi([_objective(0, "zone", "x")]), "", "no warehouse: any town hall")


func test_turn_in_waits_for_every_required_objective() -> void:
	var done := _objective(0, "warehouse", "a", "completed")
	assert_true(MissionKioskUI.ready_to_turn_in([done, _objective(1, "warehouse", "b", "pending", true)]),
		"a bonus objective is not required")
	assert_false(MissionKioskUI.ready_to_turn_in([done, _objective(1, "warehouse", "b")]))
	assert_false(MissionKioskUI.ready_to_turn_in([]), "nothing to turn in")


func test_the_sheet_shows_each_objective_progress() -> void:
	var started := _objective(0, "warehouse", "a", "in_progress")
	started["currentProgress"] = 20
	assert_eq(MissionKioskUI.progress_suffix(started), "  —  20 / 66")
	assert_eq(MissionKioskUI.progress_suffix(_objective(0, "warehouse", "a")), "", "nothing counted yet")
	assert_string_contains(MissionKioskUI.progress_suffix(_objective(0, "warehouse", "a", "completed")), "—")


func test_a_mission_notification_lights_the_missions_tab() -> void:
	assert_eq(PlayerClient.app_of_notification("mission.ready"), "missions")
	assert_eq(PlayerClient.app_of_notification("friend_request_received"), "social")
	assert_eq(PlayerClient.app_of_notification(""), "", "nothing to light")


func test_a_goods_move_counted_for_a_mission_is_told_to_its_player() -> void:
	var text := ChatNetwork.notification_text({"type": "mission.progress", "data": {"title": "Gold run"}})
	assert_string_contains(text, "Gold run")
	assert_eq(PlayerClient.app_of_notification("mission.progress"), "missions")


func test_the_participants_read_as_names() -> void:
	var participants := [{"playerId": "4aa97da7-6ae4", "name": "player-kira"}, {"playerId": "b91c2854-3ae4", "name": null}]
	assert_eq(ServiceTypes.participants_text(participants), "player-kira, b91c2854")
	assert_eq(ServiceTypes.participants_text(null), "")


func test_a_warehouse_transport_lists_its_steps_and_ticks_them() -> void:
	var objective := {"type": "transport", "params": {"via": "warehouse", "goodType": "ore.gold"},
			"locationFrom": {"village": "M0001"}, "locationTo": {"village": "F0001"}}
	var steps := ServiceTypes.transport_steps(objective)
	assert_eq(steps.size(), 2, "the same good: load, deliver")
	assert_string_contains(steps[0], "M0001")
	assert_string_contains(steps[1], "F0001")
	assert_true(steps[0].begins_with("•"), "not loaded yet")
	objective["state"] = {"loadedAt": "2026-11-06T20:00:00Z"}
	assert_true(ServiceTypes.transport_steps(objective)[0].begins_with("✓"), "once loaded, ticked")
	assert_eq(ServiceTypes.transport_steps({"type": "deliver_material", "params": {"via": "warehouse"}}).size(), 0)


func test_a_refining_transport_names_its_refinery_between_the_two() -> void:
	var objective := {"type": "transport", "params": {"via": "warehouse", "goodType": "ore.gold",
			"deliverGoodType": "ingot.gold"}, "locationFrom": {"village": "M0001"},
			"locationTo": {"village": "M0003"}, "payload": {"refineAt": "F0001"}}
	var steps := ServiceTypes.transport_steps(objective)
	assert_eq(steps.size(), 3, "load, refine, deliver")
	assert_string_contains(steps[1], "F0001", "the refinery the simulator names")
	objective.erase("payload")
	assert_eq(ServiceTypes.transport_steps(objective)[1].count("%s"), 0, "none named: a factory city")


func test_a_running_assignment_says_nothing_a_paid_one_its_reward() -> void:
	assert_eq(ServiceTypes.assignment_line({"status": "active", "rewardSettled": false}), "")
	assert_string_contains(ServiceTypes.assignment_line({"status": "completed", "rewardSettled": true,
			"rewardAmount": 841}), "841")


func test_a_quantity_reads_in_its_unit() -> void:
	assert_eq(ServiceTypes.quantity_text(90, "kg"), "90 kg")
	assert_eq(ServiceTypes.quantity_text(1500, "kg"), "1.5 t")
	assert_eq(ServiceTypes.quantity_text(2000, "kg"), "2 t")
	assert_eq(ServiceTypes.quantity_text(400, "l"), "400 L")
	assert_eq(ServiceTypes.quantity_text(20000, "L"), "20 m³")
	assert_eq(ServiceTypes.quantity_text(12, "m3"), "12 m³")
	assert_eq(ServiceTypes.quantity_text(3, "unit"), "3")
	assert_eq(ServiceTypes.quantity_text(3, null), "3")


func test_an_inventory_stack_reads_as_a_good_and_its_weight() -> void:
	assert_string_contains(ServiceTypes.good_label("ingot.gold"), str(TranslationServer.translate("%%MINERAL_GOLD")))
	assert_eq(ServiceTypes.good_quantity("ingot.gold", 30.0), "30 kg", "whole kilograms, not 30.0")
	assert_eq(ServiceTypes.good_quantity("ore.gold", 1500.0), "1.5 t")
	assert_eq(ServiceTypes.good_quantity("water", 4.0), "4", "other goods: units")
	assert_eq(ServiceTypes.good_label("water"), "water", "a good the game does not spell out: as named")


func test_a_mission_invitation_names_who_sent_it() -> void:
	var envelope := {"type": "mission.invited", "data": {"title": "Gold run", "fromPlayerId": "4aa97da7-6ae4"}}
	var text := ChatNetwork.notification_text(envelope, {"4aa97da7-6ae4": "player-kira"})
	assert_string_contains(text, "player-kira")
	assert_string_contains(text, "Gold run")
