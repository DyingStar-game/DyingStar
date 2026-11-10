extends GutTest

## Who orders a mission, as a player reads it: the entity's name and what it is ("ARES · Corporation"), from
## what its simulator says (`payload.issuer`) -- never the issuer type "politics" (lore, 2026-11-10: ARES is a
## corporation, and nothing presents it as a political body).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_issuer_kind.gd


func _mission(issuer: Variant) -> Dictionary:
	var payload := {"source": "universesimulator"}
	if issuer != null:
		payload["issuer"] = issuer
	return {"issuerType": "politics", "escrowPayerType": "politics", "objectives": [{"payload": payload}]}


func test_an_issuer_reads_by_its_name_and_kind() -> void:
	var mission := _mission({"name": "ARES", "kind": "corporation"})
	assert_eq(ServiceTypes.issuer_text(mission), "ARES · %s" % TranslationServer.translate("%%ENTITY_KIND_CORPORATION"))
	assert_eq(ServiceTypes.escrow_payer_text(mission), "ARES", "it pays from its own treasury: by its name")


func test_a_kind_the_game_does_not_know_shows_the_name_alone() -> void:
	assert_eq(ServiceTypes.issuer_text(_mission({"name": "Tarsis League", "kind": "trade_league"})), "Tarsis League")


func test_politics_is_never_shown_raw() -> void:
	var mission := _mission(null)
	assert_ne(ServiceTypes.issuer_text(mission), "politics")
	assert_eq(ServiceTypes.issuer_text(mission), TranslationServer.translate("%%SVC_ENUM_PAYER_POLITICS"))
	assert_eq(ServiceTypes.escrow_payer_text(mission), TranslationServer.translate("%%SVC_ENUM_PAYER_POLITICS"))
	assert_eq(ServiceTypes.escrow_payer_text({}), "", "a mission that does not say who pays")


func test_a_players_corporation_keeps_its_own_type() -> void:
	var mission := {"issuerType": "corporation", "escrowPayerType": "corporation", "objectives": []}
	assert_eq(ServiceTypes.issuer_text(mission), TranslationServer.translate("%%SVC_ENUM_ISSUER_CORPORATION"))
	assert_true(ServiceTypes.ENTITY_KIND_KEYS.has("corporation") and ServiceTypes.ISSUER_TYPE_KEYS.has("corporation"),
			"two tables: an entity's kind is not an issuer type")
