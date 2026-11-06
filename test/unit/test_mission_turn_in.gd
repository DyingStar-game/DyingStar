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


func test_the_participants_read_as_names() -> void:
	var participants := [{"playerId": "4aa97da7-6ae4", "name": "player-kira"}, {"playerId": "b91c2854-3ae4", "name": null}]
	assert_eq(ServiceTypes.participants_text(participants), "player-kira, b91c2854")
	assert_eq(ServiceTypes.participants_text(null), "")
