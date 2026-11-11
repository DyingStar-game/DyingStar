extends GutTest

## The DataPad's bank lists a transaction by what it is (the mission it pays), its type in the player's
## language and a date a player reads (playtest 2026-11-10: "mission_reward" over an ISO date).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_bank_transactions.gd


func test_a_type_reads_in_the_players_language() -> void:
	assert_eq(ServiceTypes.transaction_type_label("mission_reward"),
			TranslationServer.translate("%%SVC_TX_MISSION_REWARD"))
	assert_ne(ServiceTypes.transaction_type_label("mission_reward"), "mission_reward", "translated")
	assert_eq(ServiceTypes.transaction_type_label("something_new"), "something_new", "unknown: as it is")
	assert_eq(ServiceTypes.transaction_type_label(null), "—")


func test_a_mission_reward_names_its_mission() -> void:
	assert_eq(ServiceTypes.transaction_mission_id({"reference": "mission:abc"}), "abc")
	assert_eq(ServiceTypes.transaction_mission_id({"reference": "mission_escrow"}), "")
	assert_eq(ServiceTypes.transaction_mission_id({}), "")


func test_a_date_reads_day_month_year_and_time_in_the_players_zone() -> void:
	assert_eq(ServiceTypes.date_time_text("2026-11-08T14:26:06.102Z", 60), "08/11/2026 15:26", "an hour ahead")
	assert_eq(ServiceTypes.date_time_text("2026-11-08T14:26:06.102Z", 0), "08/11/2026 14:26", "UTC")
	assert_eq(ServiceTypes.date_time_text("2026-11-08T02:10:00Z", -300), "07/11/2026 21:10", "the day before")
	assert_eq(ServiceTypes.date_time_text(null), "—")
