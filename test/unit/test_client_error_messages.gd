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
