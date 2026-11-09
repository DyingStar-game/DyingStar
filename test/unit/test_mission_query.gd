extends GutTest
## The mission screens' filters and orders (MissionQuery): by category and by giver, best paid,
## soonest due and newest first, and what to do with a mission that pays nothing or never ends.

const MISSIONS: Array = [
	{"id": "a", "title": "Ore run", "category": "mining", "giverFaction": "ares", "giverDivision": "mining",
		"rewards": [{"type": "credits", "currency": "credits", "amount": 500}],
		"expiresAt": "2026-11-05T10:00:00.000Z", "createdAt": "2026-11-01T10:00:00.000Z"},
	{"id": "b", "title": "Crate to Tarsis", "category": "delivery", "giverFaction": "ares", "giverDivision": "hauling",
		"rewards": [{"type": "credits", "currency": "credits", "amount": 1200},
			{"type": "item", "itemId": "ore", "quantity": 2}],
		"expiresAt": "2026-11-04T23:00:00.000Z", "createdAt": "2026-11-03T10:00:00.000Z"},
	{"id": "c", "title": "Look around", "category": "divers", "issuerType": "system",
		"rewards": null, "expiresAt": null, "createdAt": "2026-11-04T10:00:00.000Z"},
]


func _ids(missions: Array) -> Array:
	return missions.map(func(m: Dictionary) -> String: return str(m["id"]))


func test_best_paid_first_and_the_unpaid_last() -> void:
	assert_eq(_ids(MissionQuery.apply(MISSIONS, "", "", MissionQuery.Sort.REWARD)), ["b", "a", "c"])
	assert_eq(MissionQuery.credits_of(MISSIONS[1]), 1200, "only the credits count, not the item")
	assert_eq(MissionQuery.credits_of(MISSIONS[2]), 0)


func test_soonest_due_first_and_the_endless_last() -> void:
	assert_eq(_ids(MissionQuery.apply(MISSIONS, "", "", MissionQuery.Sort.EXPIRY)), ["b", "a", "c"])
	assert_true(is_inf(MissionQuery.time_of(MISSIONS[2], "expiresAt")), "no end")


func test_newest_first() -> void:
	assert_eq(_ids(MissionQuery.apply(MISSIONS, "", "", MissionQuery.Sort.NEWEST)), ["c", "b", "a"])


func test_by_category_the_service_divers_being_generic() -> void:
	assert_eq(_ids(MissionQuery.apply(MISSIONS, "mining")), ["a"])
	assert_eq(_ids(MissionQuery.apply(MISSIONS, "generic")), ["c"], "the service's \"divers\"")
	assert_eq(MissionQuery.apply(MISSIONS, "combat"), [], "none of that kind")


func test_by_giver() -> void:
	assert_eq(_ids(MissionQuery.apply(MISSIONS, "", "ares/hauling")), ["b"])
	assert_eq(_ids(MissionQuery.apply(MISSIONS, "", "ares/hauling", MissionQuery.Sort.NEWEST)), ["b"])


func test_the_list_given_is_left_alone() -> void:
	var copy: Array = MISSIONS.duplicate()
	MissionQuery.apply(copy, "mining", "", MissionQuery.Sort.NEWEST)
	assert_eq(_ids(copy), ["a", "b", "c"])


func test_the_filters_offer_only_what_is_on_offer() -> void:
	var facets: Array = MissionQuery.facets(MISSIONS)
	assert_eq(facets[0], PackedStringArray(["mining", "delivery", "generic"]), "the categories found")
	var keys: Array = (facets[1] as Array).map(func(g: MissionGiver) -> String: return g.key())
	assert_eq(keys, ["ares/mining", "ares/hauling", "/"], "each giver once, the neutral one included")


func test_time_left() -> void:
	var end: float = MissionQuery.time_of(MISSIONS[0], "expiresAt")
	assert_eq(MissionQuery.seconds_left(MISSIONS[0], end - 3600.0), 3600)
	assert_eq(MissionQuery.seconds_left(MISSIONS[0], end + 10.0), 0, "over, not negative")
	assert_eq(MissionQuery.seconds_left(MISSIONS[2], end), -1, "no end")


func test_once_taken_the_players_own_deadline_comes_first() -> void:
	var end: float = MissionQuery.time_of(MISSIONS[0], "expiresAt")
	var assignment := {"deadlineAt": "2026-11-05T08:00:00.000Z"}
	assert_eq(MissionQuery.seconds_left(MISSIONS[0], end - 3 * 3600.0, assignment), 3600, "2 h before the mission's end")
	assert_eq(MissionQuery.seconds_left(MISSIONS[2], end, {}), -1, "no deadline of their own: the mission's")


func test_not_taken_it_says_its_time_limit_taken_the_time_left() -> void:
	var tiered := {"id": "d", "expiresAt": null, "assignmentDeadlineHours": 4}
	assert_eq(MissionTile.deadline_line(tiered, 0.0),
			TranslationServer.translate("%%MISSION_TIME_LIMIT") % ServiceTypes.duration(4 * 3600), "not taken: its limit")
	var now: float = MissionQuery.time_of({"t": "2026-11-05T06:00:00.000Z"}, "t")
	assert_eq(MissionTile.deadline_line(tiered, now, {"deadlineAt": "2026-11-05T09:00:00.000Z"}),
			TranslationServer.translate("%%MISSION_TIME_LEFT") % ServiceTypes.duration(3 * 3600), "taken: what is left")
	assert_eq(MissionTile.deadline_line(MISSIONS[2], 0.0), TranslationServer.translate("%%MISSION_NO_DEADLINE"))
