extends GutTest
## Private conversations: topic shape, the pinned correspondent, and the log's filter.
##
## The DM transport existed with no test at all, which is why the whole feature could sit broken
## (the channel selector never reached DIRECT_MESSAGE) without anything going red. What is pinned
## here is the part that is pure and easy to get subtly wrong:
##   • the publish/subscribe topics — only <from> may write, only <to> may read;
##   • dm_sender_of() never trusting a topic addressed to somebody else;
##   • the log showing ONE conversation, so a DM from a third party is not printed into it.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##         -gtest=res://test/unit/test_chat_dm.gd -gexit

const CHAT_NETWORK := preload("res://scenes/globals/chat_network.gd")

const ME := "9161e6a5-5b17-45ed-8652-b9eac4e133c6"
const PEER := "530ce3f0-3354-4798-b810-8a8a3d78ea70"


# ── Topics ───────────────────────────────────────────────────────────────────

## Outgoing: we are the sender, the peer the recipient.
func test_the_publish_topic_carries_both_ids() -> void:
	assert_eq(CHAT_NETWORK.dm_publish_topic(ME, PEER), "chat/dm/%s/%s" % [ME, PEER])


## Incoming: one wildcard covers every correspondent, so a message can arrive before the thread
## has even been opened.
func test_the_subscribe_topic_is_a_wildcard_over_the_senders() -> void:
	assert_eq(CHAT_NETWORK.dm_subscribe_topic(ME), "chat/dm/+/%s" % ME)


func test_the_topic_is_directional() -> void:
	# Reading our own address back as a peer would make a player message themselves.
	assert_ne(CHAT_NETWORK.dm_publish_topic(ME, PEER), CHAT_NETWORK.dm_subscribe_topic(ME))


# ── Reading the sender back ──────────────────────────────────────────────────

func test_the_sender_comes_out_of_the_topic() -> void:
	assert_eq(CHAT_NETWORK.dm_sender_of("chat/dm/%s/%s" % [PEER, ME], ME), PEER)


## Never trusted unless it is really addressed to us: this is what stops a message from one
## conversation being filed under another.
func test_a_topic_addressed_to_somebody_else_yields_no_sender() -> void:
	assert_eq(CHAT_NETWORK.dm_sender_of("chat/dm/%s/%s" % [PEER, "someone-else"], ME), "")


func test_a_malformed_topic_yields_no_sender() -> void:
	# Wrong depth, wrong prefix, empty me — all must be refused rather than half-parsed.
	assert_eq(CHAT_NETWORK.dm_sender_of("chat/dm/%s" % ME, ME), "")
	assert_eq(CHAT_NETWORK.dm_sender_of("chat/dm/%s/%s" % [PEER, ME], ""), "")
	assert_eq(CHAT_NETWORK.dm_sender_of("group/%s/%s" % [PEER, ME], ME), "")


# ── Notification feed ────────────────────────────────────────────────────────

func test_the_notification_feed_is_mine_only() -> void:
	assert_true(CHAT_NETWORK.is_my_notify_topic("notify/" + ME, ME))
	assert_false(CHAT_NETWORK.is_my_notify_topic("notify/" + PEER, ME))
	assert_false(CHAT_NETWORK.is_my_notify_topic("", ME))


# ── The log filter ───────────────────────────────────────────────────────────

## A private message is shown only when it belongs to the pinned thread. Shared channels are
## never filtered — there is one of each, everybody sees them.
func test_a_dm_is_shown_only_for_the_pinned_correspondent() -> void:
	assert_true(_visible(make_message(PEER), PEER),
			"the pinned correspondent's own message")
	assert_false(_visible(make_message(PEER), ME),
			"ourselves: our own player id is not the pinned peer's")
	assert_false(_visible(make_message(PEER), ""),
			"no thread pinned: a private message has nowhere to belong")


func test_a_shared_channel_message_is_never_filtered() -> void:
	var group := make_message(PEER, DirectChat.ChannelE.GROUP)
	assert_true(_visible(group, PEER), "a group message shows whatever thread is pinned")
	assert_true(_visible(group, ""), "and with none pinned")


## The rule itself, lifted out of the panel so it can be tested without a live scene: does this
## message belong in the log the player is reading? Kept in step with
## [method DirectChat.receive_message_from_server], which applies the same test — a DM whose peer
## is not the pinned one is held back (ChatNetwork keeps that correspondent as pending instead),
## while a shared channel always shows.
func _visible(message: ChatMessage, pinned_peer: String) -> bool:
	if message.channel != DirectChat.ChannelE.DIRECT_MESSAGE:
		return true
	return message.peer_id == pinned_peer


func make_message(peer_id: String, channel: int = DirectChat.ChannelE.DIRECT_MESSAGE) -> ChatMessage:
	return ChatMessage.new("salut", channel, "Quelqu_un", 0.0, peer_id)