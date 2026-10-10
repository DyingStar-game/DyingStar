extends GutTest
## The chat transport's topic grammar, pinned against what the broker's ACL actually allows
## (services/textchat — chatauth): `chat/global`, `chat/dm/<from>/<to>`,
## `chat/group/<groupId>`, `chat/corporation/<corporationId>`, `notify/<playerId>`.
##
## A drift here is invisible in local dev — the legacy chat/# allow-list fail-OPENS every topic —
## and cuts the moment the broker runs in JWT mode. Since the DM rewrite and the ALLIANCE →
## CORPORATION rename, the topics are no longer what any of them used to be; this is the file that
## says so out loud.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##         -gtest=res://test/unit/test_chat_topics.gd -gexit

const CHAT_NETWORK := preload("res://scenes/globals/chat_network.gd")

const ME := "player-aaa"
const PEER := "player-bbb"


func test_general_channel_uses_the_grammar_topic() -> void:
	# Was "chat/general" (one word, tolerated by nothing but the fail-open chat/# allow-list).
	assert_eq(CHAT_NETWORK._STATIC_TOPICS[DirectChat.ChannelE.GENERAL], "chat/global")


func test_context_channels_use_their_grammar_topics() -> void:
	assert_eq(CHAT_NETWORK._TOPIC_TEMPLATES[DirectChat.ChannelE.GROUP], "chat/group/%s")
	# Was "chat/alliance/%s" — chatauth has no alliance channel, only corporation.
	assert_eq(CHAT_NETWORK._TOPIC_TEMPLATES[DirectChat.ChannelE.CORPORATION], "chat/corporation/%s")
	assert_false(CHAT_NETWORK._TOPIC_TEMPLATES.has(DirectChat.ChannelE.DIRECT_MESSAGE),
			"DM needs a peer id on BOTH ends of its topic: it is handled by its own helpers")


func test_channel_enum_is_corporation_everywhere() -> void:
	# The rename must reach the enum and its labels — the UI shows the enum NAME.
	assert_eq(DirectChat.ChannelE.CORPORATION, 3)
	assert_eq(DirectChat.ChannelE.keys()[3], "CORPORATION")
	assert_eq(DirectChat.CHANNEL_LABELS["CORPORATION"], "%%CHAT_CORPORATION")
	assert_false(DirectChat.CHANNEL_LABELS.has("ALLIANCE"), "the alliance label is gone")


func test_dm_publish_topic_carries_both_ids() -> void:
	# Only <from> may write it and only <to> may read it, so both ends must be in the topic.
	assert_eq(CHAT_NETWORK.dm_publish_topic(ME, PEER), "chat/dm/player-aaa/player-bbb")
	assert_eq(CHAT_NETWORK.dm_publish_topic(PEER, ME), "chat/dm/player-bbb/player-aaa")


func test_dm_subscribe_topic_wildcards_the_sender() -> void:
	# One filter covers every conversation addressed to us — no per-peer subscribe to keep in sync.
	assert_eq(CHAT_NETWORK.dm_subscribe_topic(ME), "chat/dm/+/player-aaa")


func test_dm_sender_of_reads_the_from_segment() -> void:
	assert_eq(CHAT_NETWORK.dm_sender_of("chat/dm/player-bbb/player-aaa", ME), "player-bbb")


func test_dm_sender_of_rejects_a_topic_addressed_to_someone_else() -> void:
	# We should never even receive one, but a topic is never trusted for WHO wrote it.
	assert_eq(CHAT_NETWORK.dm_sender_of("chat/dm/player-bbb/player-ccc", ME), "")


func test_dm_sender_of_rejects_malformed_topics() -> void:
	assert_eq(CHAT_NETWORK.dm_sender_of("chat/dm/player-bbb", ME), "")
	assert_eq(CHAT_NETWORK.dm_sender_of("chat/dm/a/b/c", ME), "")
	assert_eq(CHAT_NETWORK.dm_sender_of("chat/general", ME), "")
	assert_eq(CHAT_NETWORK.dm_sender_of("group/player-bbb/player-aaa", ME), "")
	# No identity at all (no token, no Horizon id): a DM has no sender we can name.
	assert_eq(CHAT_NETWORK.dm_sender_of("chat/dm/player-bbb/x", ""), "")


func test_notify_topic_matches_only_my_feed() -> void:
	assert_true(CHAT_NETWORK.is_my_notify_topic("notify/" + ME, ME))
	assert_false(CHAT_NETWORK.is_my_notify_topic("notify/" + PEER, ME))
	assert_false(CHAT_NETWORK.is_my_notify_topic("notify/" + ME + "/x", ME))
	assert_false(CHAT_NETWORK.is_my_notify_topic("notify/", ME))


func test_parse_notification_reads_the_envelope() -> void:
	var envelope: Dictionary = CHAT_NETWORK.parse_notification(
			'{"id":"1","type":"friend.request","title":"Hi","body":"yo","sentAt":"2026-10-10T12:00:00Z"}')
	assert_eq(envelope.get("type"), "friend.request")
	assert_eq(envelope.get("title"), "Hi")
	assert_eq(envelope.get("body"), "yo")


func test_parse_notification_rejects_non_objects() -> void:
	assert_eq(CHAT_NETWORK.parse_notification("not json"), {})
	assert_eq(CHAT_NETWORK.parse_notification("[1, 2]"), {})
	assert_eq(CHAT_NETWORK.parse_notification('"a string"'), {})
	assert_eq(CHAT_NETWORK.parse_notification(""), {})


func test_group_and_corporation_ids_are_read_from_whatever_name_the_service_used() -> void:
	assert_eq(CHAT_NETWORK._id_of({"id": 7}), "7")
	assert_eq(CHAT_NETWORK._id_of({"groupId": "g-1"}), "g-1")
	assert_eq(CHAT_NETWORK._id_of({"corporationId": "corp-9"}), "corp-9")
	assert_eq(CHAT_NETWORK._id_of(null), "")
	assert_eq(CHAT_NETWORK._id_of({}), "")


func test_first_row_id_of_a_list_response() -> void:
	assert_eq(CHAT_NETWORK._first_row_id({"data": {"items": [{"id": "corp-1"}]}}), "corp-1")
	assert_eq(CHAT_NETWORK._first_row_id({"data": [{"id": "corp-2"}]}), "corp-2")
	assert_eq(CHAT_NETWORK._first_row_id({"data": {"items": []}}), "")
	assert_eq(CHAT_NETWORK._first_row_id({"data": null}), "")
	assert_eq(CHAT_NETWORK._first_row_id({}), "")
