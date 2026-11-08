extends GutTest
## Who gives a mission, as the screens show it: the ARES subsidiaries straight from AresBrand (never a
## copied colour), a faction without a division standing for the faction itself, and a mission whose
## giver the game does not know keeping a neutral look named after its issuer.


func test_every_ares_subsidiary_is_a_giver_in_its_brand_colour() -> void:
	for subsidiary: int in AresBrand.Subsidiary.values():
		var giver := MissionGivers.find("ares", AresMissionGiver.slug_of(subsidiary))
		assert_not_null(giver, "ARES %s gives missions" % AresBrand.name_of(subsidiary))
		assert_eq(giver.colour(), AresBrand.colour(subsidiary), "its colour is the brand's")
		assert_eq(giver.display_name(), "ARES %s" % AresBrand.name_of(subsidiary))


func test_the_service_slugs_are_the_subsidiaries_in_lower_case() -> void:
	assert_eq(AresMissionGiver.slug_of(AresBrand.Subsidiary.MINING), "mining")
	assert_eq(AresMissionGiver.slug_of(AresBrand.Subsidiary.HAULING), "hauling")
	assert_eq(MissionGivers.of_mission({"giverFaction": "ares", "giverDivision": "mining"}).key(), "ares/mining")


func test_the_faction_alone_or_an_unknown_division_is_ares_corp() -> void:
	var corp := AresBrand.colour(AresBrand.Subsidiary.CORP)
	assert_eq(MissionGivers.of_mission({"giverFaction": "ares"}).colour(), corp, "no division")
	assert_eq(MissionGivers.of_mission({"giverFaction": "ares", "giverDivision": "bakery"}).colour(), corp,
			"a division the game does not know yet")


func test_an_unknown_giver_is_neutral_and_named_after_its_issuer() -> void:
	var system := MissionGivers.of_mission({"issuerType": "system"})
	assert_eq(system.colour(), MissionGivers.NEUTRAL_TINT)
	assert_eq(system.display_name(), ServiceTypes.issuer_type_label("system"), "the issuer's name")
	var stranger := MissionGivers.of_mission({"giverFaction": "freeport", "giverDivision": "docks"})
	assert_eq(stranger.colour(), MissionGivers.NEUTRAL_TINT, "a faction without its .tres yet")
	assert_eq(stranger.display_name(), "FREEPORT", "still named")
	assert_eq(stranger.key(), "freeport/", "one filter for the whole unknown faction")


func test_a_faction_of_its_own_is_one_resource() -> void:
	var giver := MissionGiver.new()
	giver.faction = "freeport"
	giver.name_key = "Freeport"
	giver.tint = Color.CYAN
	assert_true(giver.is_faction_itself())
	assert_eq(giver.key(), "freeport/")
	assert_eq(giver.display_name(), "Freeport", "a proper noun is shown as it is")
	var logo := giver.logo_control(40.0)
	assert_true(logo is Label, "no mark: its name in its place")
	logo.free()


func test_every_giver_file_is_valid() -> void:
	for giver: MissionGiver in MissionGivers.all():
		assert_ne(giver.faction_id(), "", "a giver names its faction")
		assert_ne(giver.display_name(), "", "and has a name")


func test_a_player_mission_is_given_by_its_creator_by_name() -> void:
	var raised := {"issuerType": "player", "createdBy": "p-1", "creatorName": "Kira"}
	var giver := MissionGivers.of_mission(raised)
	assert_eq(giver.display_name(), "Kira", "the creator's pseudo")
	assert_eq(giver.colour(), MissionGivers.NEUTRAL_TINT, "no faction colour")
	assert_eq(giver.key(), "player:p-1/", "one filter per player")
	var unnamed := MissionGivers.of_mission({"issuerType": "player", "createdBy": "p-2"})
	assert_eq(unnamed.display_name(), ServiceTypes.issuer_type_label("player"), "until Social answers")


func test_the_feed_names_only_player_missions_and_asks_each_creator_once() -> void:
	var shown: Array = [
		{"issuerType": "player", "createdBy": "p-1"},
		{"issuerType": "player", "createdBy": "p-1"},
		{"issuerType": "player", "createdBy": "p-2"},
		{"issuerType": "system", "createdBy": "svc-universesimulator"},
	]
	var unknown: PackedStringArray = MissionFeed.name_creators(shown, {"p-2": "Pell"})
	assert_eq(unknown, PackedStringArray(["p-1"]), "asked once, the known one not again")
	assert_eq(shown[2].get("creatorName"), "Pell")
	assert_false(shown[3].has("creatorName"), "a service mission is not a player's")
	MissionFeed.name_creators(shown, {"p-1": ""})
	assert_false(shown[0].has("creatorName"), "a name Social did not give stays the issuer's label")
