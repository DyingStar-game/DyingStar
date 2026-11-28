extends GutTest
## A mission's done steps drawn green (ServiceStyle.step_colour), the partial turn-in offered from the
## mission service's own preview (ServiceTypes.turn_in_preview), and the notifications of a mission's steps
## (ChatNetwork): a step is news, a crate counted only refreshes.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_mission_steps_and_partial.gd -gexit


func _transport(state: Dictionary, progress: int = 0) -> Dictionary:
	return {"type": "transport", "params": {"via": "warehouse", "goodType": "ore.gold"},
		"targetQuantity": 240, "currentProgress": progress,
		"locationFrom": {"village": "M0001"}, "locationTo": {"village": "F0001"}, "state": state}


func test_a_ticked_step_is_drawn_green_the_others_as_they_were() -> void:
	var steps := ServiceTypes.transport_steps(_transport({"loadedAt": "2026-11-22T11:30:00Z", "loaded": 240}))
	assert_true(ServiceTypes.is_done_step(steps[0]), "everything loaded: done")
	assert_false(ServiceTypes.is_done_step(steps[1]), "nothing delivered yet")
	assert_eq(ServiceStyle.step_colour(steps[0], ServiceStyle.ACCENT), ServiceStyle.GOOD)
	assert_eq(ServiceStyle.step_colour(steps[1], ServiceStyle.ACCENT), ServiceStyle.ACCENT)


func test_an_objective_done_is_drawn_green() -> void:
	assert_eq(ServiceStyle.done_colour(true, ServiceStyle.TEXT_2), ServiceStyle.GOOD)
	assert_eq(ServiceStyle.done_colour(false, ServiceStyle.TEXT_2), ServiceStyle.TEXT_2)


func test_the_preview_is_the_service_s_or_nothing() -> void:
	var preview := {"shareBp": 4000, "full": false, "partial": true, "penaltyBp": 2500, "payoutBp": 3000,
		"amount": 300, "currency": "credits"}
	assert_eq(ServiceTypes.turn_in_preview({"turnIn": preview}), preview)
	assert_eq(ServiceTypes.turn_in_preview({"turnIn": null}), {}, "not the reader's active mission")
	assert_eq(ServiceTypes.turn_in_preview(null), {})


func test_a_partial_turn_in_is_offered_when_something_is_done_not_all() -> void:
	assert_true(ServiceTypes.can_turn_in_partially({"partial": true, "full": false}))
	assert_false(ServiceTypes.can_turn_in_partially({"partial": false, "full": false}),
			"nothing done: nothing to turn in")
	assert_false(ServiceTypes.can_turn_in_partially({"partial": false, "full": true}), "done: turned in in full")
	assert_false(ServiceTypes.can_turn_in_partially({}), "a service without the preview offers nothing")
	assert_eq(ServiceTypes.partial_turn_in_text({"partial": false}), "")


func test_the_offer_reads_the_service_s_figures() -> void:
	var preview := {"shareBp": 4050, "partial": true, "amount": 300, "currency": "credits"}
	assert_eq(ServiceTypes.turn_in_percent(preview), 40, "whole percent, rounded down")
	assert_eq(ServiceTypes.turn_in_amount(preview), "300 credits")
	var offer := ServiceTypes.partial_turn_in_text(preview)
	assert_string_contains(offer, "40")
	assert_string_contains(offer, "300 credits")
	assert_string_contains(ServiceTypes.partial_turn_in_confirm(preview), "300 credits")


func test_a_crate_counted_refreshes_without_a_word() -> void:
	assert_true(ChatNetwork.is_silent("mission.updated"))
	assert_false(ChatNetwork.is_silent("mission.progress"), "a step is news")
	assert_false(ChatNetwork.is_silent("mission.ready"))


func test_a_step_says_which() -> void:
	var loaded := ChatNetwork.notification_text({"type": "mission.progress",
		"data": {"title": "Gold run", "step": "loaded"}})
	var delivered := ChatNetwork.notification_text({"type": "mission.progress",
		"data": {"title": "Gold run", "step": "delivered"}})
	assert_string_contains(loaded, "Gold run")
	assert_string_contains(delivered, "Gold run")
	assert_ne(loaded, delivered)
	assert_string_contains(ChatNetwork.mission_step_text({"title": "Gold run"}), "Gold run", "no step named")


func test_a_partial_turn_in_tells_what_it_paid() -> void:
	var text := ChatNetwork.notification_text({"type": "mission.partially_completed",
		"data": {"title": "Gold run", "ratioBp": 4000, "amount": 300}})
	assert_string_contains(text, "Gold run")
	assert_string_contains(text, "40")
	assert_string_contains(text, "300")
	assert_true(ChatNetwork.is_gain("mission.partially_completed"), "money earned: one chime")


func test_the_kiosk_asks_for_a_partial_only_when_asked() -> void:
	assert_eq(MissionTurnIn.complete_body("p1", false), {"playerId": "p1"})
	assert_eq(MissionTurnIn.complete_body("p1", true), {"playerId": "p1", "partial": true})


func test_a_refused_turn_in_says_why() -> void:
	assert_eq(MissionKioskUI.turn_in_error_key("WRONG_TOWN_HALL"), "%%MISSION_TURN_IN_ELSEWHERE")
	assert_eq(MissionKioskUI.turn_in_error_key("PARTIAL_NO_PROGRESS"), "%%MISSION_PARTIAL_NOTHING_DONE")
	assert_eq(MissionKioskUI.turn_in_error_key("ERROR"), "%%MISSION_TURN_IN_FAILED")
