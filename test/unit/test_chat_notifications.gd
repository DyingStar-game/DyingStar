extends GutTest
## Social notifications: the line the player reads, and the name it attributes.
##
## social publishes `{id, type, title?, body?, data?, sentAt}` and today sends NEITHER title NOR
## body — only `type` and `data`. So the wording is ours, and the whole failure surface is "a toast
## that says nothing useful": a blank line, a raw uuid across the screen, or a sentence with a stray
## `%s` because the service's `data` did not carry what we assumed.
##
## The three types are read off the service, not guessed: friends.service.js sends
## `friend_request_received` (data.fromPlayerId) and `friend_request_accepted` (data.playerId),
## corporations.service.js sends `corporation_joined` (data.corporationId — a CORPORATION, not a
## player, so the wording must not name anybody).
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##         -gtest=res://test/unit/test_chat_notifications.gd -gexit

const CHAT_NETWORK := preload("res://scenes/globals/chat_network.gd")

const SENDER := "530ce3f0-3354-4798-b810-8a8a3d78ea70"
const NAMES := {"530ce3f0-3354-4798-b810-8a8a3d78ea70": "Alice"}


func envelope(type: String, data: Dictionary = {}) -> Dictionary:
	return {"id": "abc", "type": type, "data": data, "sentAt": "2026-10-10T21:00:00.000Z"}


# ── The three types that exist ───────────────────────────────────────────────

func test_a_friend_request_names_the_requester() -> void:
	var text: String = CHAT_NETWORK.notification_text(
			envelope("friend_request_received", {"fromPlayerId": SENDER}), NAMES)
	assert_true(text.contains("Alice"), "who sent it is in the line: %s" % text)
	assert_false(text.contains("%s"), "no unreplaced placeholder left: %s" % text)


func test_an_accepted_request_names_who_accepted() -> void:
	var text: String = CHAT_NETWORK.notification_text(
			envelope("friend_request_accepted", {"playerId": SENDER}), NAMES)
	assert_true(text.contains("Alice"), "the line says who: %s" % text)
	assert_false(text.contains("%s"), "no unreplaced placeholder left: %s" % text)


## The one type that is about the PLAYER rather than about somebody else: social notified the very
## player who joined, and its data is a corporationId. Naming a player here would print "somebody",
## which reads like a bug rather than like a sentence.
func test_joining_a_corporation_names_nobody() -> void:
	var text: String = CHAT_NETWORK.notification_text(
			envelope("corporation_joined", {"corporationId": SENDER}), NAMES)
	assert_false(text.contains("%s"), "no placeholder at all: %s" % text)
	assert_false(text.contains(SENDER), "no corporation id printed as if it were a person: %s" % text)


# ── Never blank, never raw ───────────────────────────────────────────────────

## The whole point of the fallback chain: a notification the player cannot read is worse than an
## ugly one, and a blank toast looks like the game is broken.
func test_an_unknown_type_still_says_something() -> void:
	var text: String = CHAT_NETWORK.notification_text(envelope("some_future_event", {}))
	assert_ne(text, "", "an unknown type is still a line")
	assert_true(text.contains("some_future_event"), "and says what it was: %s" % text)


func test_an_envelope_with_no_type_is_not_blank() -> void:
	var text: String = CHAT_NETWORK.notification_text({"id": "abc"})
	assert_ne(text, "", "an empty payload must not produce an empty toast")


func test_an_empty_envelope_is_dropped_before_it_reaches_the_stack() -> void:
	# push() ignores a blank line; this is the guard that keeps it from ever being called with one.
	assert_eq(CHAT_NETWORK.notification_text({}), "")


## A 36-character uuid across the top of the screen is not a notification: an unresolved peer is
## shortened so the line stays readable, and only when there is an id to shorten.
func test_an_unresolved_sender_is_shortened_never_dumped_whole() -> void:
	var name := CHAT_NETWORK.notification_name_for({"fromPlayerId": SENDER}, {})
	assert_ne(name, SENDER, "the full uuid is not shown")
	assert_eq(name, SENDER.substr(0, 8), "but the start of it is, so the player can say it apart")


func test_a_resolved_sender_is_printed_by_name() -> void:
	assert_eq(CHAT_NETWORK.notification_name_for({"fromPlayerId": SENDER}, NAMES), "Alice")


func test_both_id_keys_are_accepted() -> void:
	# fromPlayerId (a request) and playerId (an acceptance) carry the same thing under two names.
	assert_eq(CHAT_NETWORK.notification_name_for({"playerId": SENDER}, NAMES), "Alice")


func test_no_sender_at_all_reads_as_somebody() -> void:
	var name := CHAT_NETWORK.notification_name_for({}, {})
	assert_ne(name, "", "never empty")
	assert_false(name.contains("%s"), "and never a placeholder")


# ── title / body, if the service ever starts sending them ────────────────────

## They are in the contract today but never sent. If they start arriving they must win over the
## wording we compose, and body without title must not print a leading dash.
func test_a_title_from_the_service_wins_over_our_wording() -> void:
	var text: String = CHAT_NETWORK.notification_text({
		"type": "friend_request_received", "title": "Alice", "data": {"fromPlayerId": SENDER}})
	assert_eq(text, "Alice", "the service's own wording is used as-is")


func test_a_body_without_a_title_prints_no_leading_dash() -> void:
	var text: String = CHAT_NETWORK.notification_text({"type": "x", "body": "Hello"})
	assert_eq(text, "Hello")
	assert_false(text.contains("—"), "no dangling separator: %s" % text)


func test_title_and_body_are_joined() -> void:
	var text: String = CHAT_NETWORK.notification_text({"type": "x", "title": "Alice", "body": "Hi"})
	assert_true(text.contains("Alice") and text.contains("Hi"), "both parts: %s" % text)