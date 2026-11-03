extends GutTest

## Horizon refuses an init whose token has expired (the launcher refreshes it only when it launches the
## game) or is invalid, with an `error` code the client words itself: the player is told to relaunch from
## the launcher instead of waiting for the spawn watchdog (7002).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_client_error_messages.gd

const CLIENT := preload("res://server/client.gd")


func test_a_refused_token_has_our_own_wording() -> void:
	for code in [CLIENT.ERROR_TOKEN_EXPIRED, CLIENT.ERROR_TOKEN_REFUSED]:
		var text: String = CLIENT.error_message_for({"type": "error", "code": code, "message": "horizon text"})
		assert_ne(text, "horizon text", "code %d: our own wording, not Horizon's" % code)
		assert_ne(text, "", "code %d: an empty message would leave the error screen blank" % code)


func test_other_codes_keep_horizons_message() -> void:
	assert_eq(CLIENT.error_message_for({"type": "error", "code": 1338, "message": "Server not yet ready"}),
			"Server not yet ready")
	assert_eq(CLIENT.error_message_for({"type": "error", "message": "no code"}), "no code")


## The WebTransport session's end is worded after why it ended (HorizonLink.get_close_kind and the server's
## close code), never left blank: until then a lost connection only stopped the client, without a word.
func test_an_outdated_client_is_told_to_update() -> void:
	var update: String = TranslationServer.translate("%%ERR_UPDATE_REQUIRED")
	assert_eq(CLIENT.close_message_for("protocol", 0, ""), update)
	for code in [CLIENT.CLOSE_PROTOCOL_MISMATCH, CLIENT.CLOSE_SETTINGS_MISMATCH, CLIENT.CLOSE_DICTIONARY_MISMATCH]:
		assert_eq(CLIENT.close_message_for("server", code, "frames do not match"), update, "close code %d" % code)


func test_an_unreachable_server_is_not_a_lost_connection() -> void:
	var unreachable: String = CLIENT.close_message_for("timeout", 0, "no answer from the server")
	assert_ne(unreachable, "")
	assert_ne(unreachable, CLIENT.close_message_for("connection_lost", 0, "stream finished"))
	assert_eq(CLIENT.close_message_for("address", 0, "dns"), unreachable)


func test_a_kick_shows_the_servers_reason() -> void:
	assert_eq(CLIENT.close_message_for("server", CLIENT.CLOSE_KICKED, "maintenance"), "maintenance")
	assert_ne(CLIENT.close_message_for("server", CLIENT.CLOSE_KICKED, ""), "", "a kick without reason still says something")


func test_every_close_has_a_message() -> void:
	for kind in ["timeout", "address", "tls", "refused", "protocol", "server", "connection_lost"]:
		assert_ne(CLIENT.close_message_for(kind, 0, ""), "", kind)
	assert_ne(CLIENT.close_message_for("server", CLIENT.CLOSE_SERVER_FULL, ""), "")
