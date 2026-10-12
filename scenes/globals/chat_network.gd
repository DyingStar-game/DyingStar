extends Node

## Dedicated MQTT transport for the in-game text chat.
##
## Single responsibility: own the broker connection, publish outgoing messages and
## re-emit incoming ones. The UI (DirectChat) binds to this; gameplay networking
## stays in NetworkOrchestrator. Clients connect DIRECTLY to the broker — the
## broker (+ JWT auth in production) is the authority for chat, not the game server.
##
## Topics follow the grammar the broker's ACL enforces (chatauth): `chat/global`
## for the general channel; `chat/dm/<from>/<to>` for a private message, where only
## <from> may write and only <to> may read (they must be friends); `chat/group/<groupId>`
## and `chat/corporation/<corpId>` for the context channels. GROUP, CORPORATION and
## REGION need a context id and stay INACTIVE until one is registered via
## set_id_provider() — then the channel subscribes and becomes selectable on its own.
## ChatNetwork wires GROUP and CORPORATION itself from the caller's own social
## membership once the services are reachable; a DM conversation is opened with
## start_dm(peer_id).
##
## Two subscriptions have no channel of their own and live from the first connection:
## the DM wildcard `chat/dm/+/<my id>` (so a message can arrive before its thread has
## even been opened — the sender id is read back out of the topic) and the player's
## notification feed `notify/<my id>`, re-emitted as [signal notification_received].
##
## How a notification names the player it concerns: their display name when the caller resolved
## it, and a neutral wording when it does not have one. Kept here so the transport owns the whole
## vocabulary of a notification, envelope in and text out.
const NOTIFICATION_UNKNOWN_NAME: String = "%%NOTIF_UNKNOWN_NAME"


## The one-line text for [param envelope], ready to show.
##
## social publishes `{id, type, title?, body?, data?, sentAt}` and today sends NEITHER title NOR body
## — only `type` and `data` (friends.service.js, corporations.service.js). The wording is therefore
## ours: [param names] maps a player id to the name to print, so a friend request says WHO asked
## rather than "somebody did".
##
## Deliberately total: a type we have never seen, a missing name and a payload with nothing in it
## all still produce a line. A notification the player cannot read is worse than an ugly one, and a
## blank toast looks like the game is broken.
static func notification_text(envelope: Dictionary, names: Dictionary = {}) -> String:
	if envelope.is_empty():
		return ""
	# title/body first: if the service ever starts sending them, they win over anything we would
	# compose, which is the whole point of having them in the contract.
	var title := str(envelope.get("title", ""))
	var body := str(envelope.get("body", ""))
	if body != "":
		return title if title == "" else "%s — %s" % [title, body]
	if title != "":
		return title

	var data: Dictionary = envelope.get("data") if envelope.get("data") is Dictionary else {}
	var type := str(envelope.get("type", ""))
	var who := notification_name_for(data, names)
	match type:
		"friend_request_received":
			return TranslationServer.translate("%%NOTIF_FRIEND_REQUEST_RECEIVED") % who
		"friend_request_accepted":
			return TranslationServer.translate("%%NOTIF_FRIEND_REQUEST_ACCEPTED") % who
		"corporation_joined":
			# No actor: this one's about YOU (the service notified the player who joined), and its
			# data is a corporationId, so there is nobody to name.
			return TranslationServer.translate("%%NOTIF_CORPORATION_JOINED")
		_:
			# An unknown type is still worth saying out loud, as long as it is never blank.
			if type == "":
				return TranslationServer.translate("%%NOTIF_GENERIC_BARE")
			return TranslationServer.translate("%%NOTIF_GENERIC") % type


## The player [param data] concerns, as a name to print: the one the caller resolved, else the id
## shortened to something recognisable, else a neutral "somebody". The id is NEVER printed whole —
## a 36-character uuid across the top of the screen is not a notification.
static func notification_name_for(data: Dictionary, names: Dictionary = {}) -> String:
	var player_id := str(data.get("fromPlayerId", ""))
	if player_id == "":
		player_id = str(data.get("playerId", ""))
	if player_id == "":
		return TranslationServer.translate(NOTIFICATION_UNKNOWN_NAME)
	var resolved := str(names.get(player_id, ""))
	if resolved != "":
		return resolved
	return player_id.substr(0, 8) if player_id.length() > 8 else player_id


## Identity: the JWT `sub` when a token is present (the id the server reports to social
## and the broker's ACL matches on), the Horizon player id otherwise (token-less dev),
## then the locally generated uuid as a last resort.

signal message_received(message: ChatMessage)
## Emitted when the set of usable channels changes (a provider was (un)registered),
## so the UI can refresh which channels are selectable.
signal channels_changed
## A social notification envelope arrived on `notify/<my id>` — {id, type, title?, body?,
## data?, sentAt}. The UI decides what to do with it; this transport only delivers.
signal notification_received(payload: Dictionary)
## The player asked to open a private conversation with [param peer_id] (contacts app →
## "Message"): the DM provider is already registered, the UI only has to pin the thread.
signal dm_requested(peer_id: String)
## The pinned private conversation changed (or closed when [param peer_id] is empty). The UI
## shows the correspondent's name in the message box and filters the log to that thread.
signal dm_peer_changed(peer_id: String, display_name: String)
## A correspondent's display name arrived from social, so the pinned bar can stop reading
## « résolution… » and show the real name. Separate from [signal dm_peer_changed] because a
## name can land for a thread that is not the pinned one.
signal peer_name_resolved(peer_id: String, display_name: String)
## A private message arrived from a peer who is not the pinned one: the UI marks them as
## having something new, without dropping the message or mixing it into another thread.
signal pending_dm_peer(peer_id: String, display_name: String)
## The broker connection changed state. The Diagnostics app shows it to the player: a chat that is
## silently retrying is otherwise invisible — it just swallows every publish (see
## _teardown_and_retry).
signal state_changed(state: int)

enum State {
	IDLE,
	CONNECTING,
	CONNECTED,
	RETRYING,
}

const _MQTT_SCENE := preload("res://addons/mqtt/mqtt.tscn")

# Default broker endpoint (local dev). Overridable via client.ini [chat] broker_url.
const _DEFAULT_BROKER_URL := "ws://127.0.0.1:9001"

# Channels reachable with a fixed topic (no context id needed).
const _STATIC_TOPICS := {
	DirectChat.ChannelE.GENERAL: "chat/global",
}

# Channels whose topic needs a context id supplied by a provider (the "sockets").
# DIRECT_MESSAGE is deliberately absent: its PUBLISH topic carries two ids (me -> peer)
# while its subscription is the single wildcard filter "chat/dm/+/<me>", so neither this
# map nor one id alone can describe it — see dm_publish_topic()/dm_subscribe_topic().
const _TOPIC_TEMPLATES := {
	DirectChat.ChannelE.REGION: "chat/region/%s",
	DirectChat.ChannelE.GROUP: "chat/group/%s",
	DirectChat.ChannelE.CORPORATION: "chat/corporation/%s",
}

# Prefix of the player notification feed; the full topic is "notify/<my id>".
const _NOTIFY_PREFIX := "notify/"

# Reconnect backoff. The broker drops us for ordinary reasons (pod restart,
# network blip); without a retry the chat stays dead for the whole session and
# publishes vanish silently, because the addon's senddata() no-ops once its
# socket is null.
const _RECONNECT_DELAY_MIN := 2.0
const _RECONNECT_DELAY_MAX := 30.0

var _client: Node = null
var _connected: bool = false
# Broker connection state (see [enum State]); the Diagnostics app reads it.
var state: int = State.IDLE
# Resolved broker endpoint, read once from client.ini (see broker_endpoint()).
var _broker_endpoint: String = ""
# channel (int) -> Callable() returning the context id (String), or "" when none.
var _id_providers: Dictionary = {}
# Topics we hold a live subscription for, so we can drop the stale ones when a
# context id changes. Cleared on teardown: the broker session goes with it.
var _subscribed_topics: Dictionary = {}
# True once someone asked for a connection, so a retry knows chat is still wanted.
var _wants_connection: bool = false
var _reconnect_delay: float = _RECONNECT_DELAY_MIN
var _reconnect_timer: Timer = null
# GROUP/CORPORATION providers wired once per session (re-wired on reconnect, and
# refreshed whenever a membership mutation announces itself on PlayerServices.changed).
var _contexts_wired: bool = false
# Social player id -> display name, for the private conversations. Only peers we have
# actually spoken to, so the picker offers the people the player has a thread with rather
# than every contact. Filled by start_dm() (the contact card knows the name for free) and
# by resolve_peer_name() for a peer that arrives from the wire carrying nothing but its id.
var _peer_names: Dictionary = {}
# Peers whose DM arrived while they were NOT the pinned one: the player is told there is a
# new message without the log losing track of whose thread it belongs to. Cleared when the
# peer is pinned, or when the player opens that thread.
var _pending_dm_peers: Dictionary = {}

func _ready() -> void:
	_reconnect_timer = Timer.new()
	_reconnect_timer.one_shot = true
	_reconnect_timer.timeout.connect(_on_reconnect_timeout)
	add_child(_reconnect_timer)

## Connect to the broker if not already connecting/connected. Safe to call many
## times. No-op on the headless dedicated server (chat is a client feature).
func ensure_connected() -> void:
	if OS.has_feature("dedicated_server"):
		return
	_wants_connection = true
	if _client != null:
		return
	# A retry is already pending; let the backoff run instead of hammering.
	if _reconnect_timer != null and not _reconnect_timer.is_stopped():
		return
	_open_connection()


## The broker endpoint we connect to ([chat] broker_url in client.ini, or the local
## default). The Diagnostics app shows it so a player can see WHICH broker a chat fail
## was talking about (telepresence, in-cluster name, 127.0.0.1 port-forward). Read once
## and kept: client.ini is not meant to be edited under a running client.
func broker_endpoint() -> String:
	if _broker_endpoint == "":
		var config := ConfigFile.new()
		if config.load("client.ini") == OK and config.has_section_key("chat", "broker_url"):
			_broker_endpoint = str(config.get_value("chat", "broker_url", _DEFAULT_BROKER_URL))
		else:
			_broker_endpoint = _DEFAULT_BROKER_URL
	return _broker_endpoint


## Publish the connection state, once per actual change (IDLE on a no-op stays IDLE).
func _set_state(next: int) -> void:
	if state == next:
		return
	state = next
	state_changed.emit(next)

func _open_connection() -> void:
	var url := broker_endpoint()
	_set_state(State.CONNECTING)

	_client = _MQTT_SCENE.instantiate()
	add_child(_client)
	_client.received_message.connect(_on_broker_message)
	_client.broker_connected.connect(_on_broker_connected)
	_client.broker_connection_failed.connect(_on_broker_connection_failed)
	_client.broker_disconnected.connect(_on_broker_disconnected)

	# Auth: reuse the game JWT (set on the client network agent from --token=).
	# mosquitto-go-auth (jwt backend) reads the token from the MQTT USERNAME and just
	# needs the password to be non-empty. The anonymous dev broker ignores both, so an
	# empty token (local dev) is fine — we simply connect without credentials then.
	# Go through set_user_pass(): the addon encodes `user`/`pswd` straight into the
	# CONNECT packet and needs them as PackedByteArray, so assigning the Strings
	# directly crashes in encodevarstr() the moment a token is present.
	var token := _player_token()
	if token != "":
		_client.set_user_pass(token, "jwt")
	if Globals.player_uuid != "":
		_client.client_id = "ds-" + Globals.player_uuid

	var proto := "ws://"
	var host := "127.0.0.1"
	var port := 9001
	var parsed := _parse_broker_url(url)
	if not parsed.is_empty():
		proto = parsed["proto"]
		host = parsed["host"]
		port = parsed["port"]
	print("[chat] connecting to broker %s%s:%d" % [proto, host, port])
	_client.connect_to_broker(proto, host, port)

## Publish a message on its channel's topic. The author is stamped here from the
## local player identity so the UI never has to know it. Ignored if the channel is
## inactive or the broker is not connected.
func publish_message(message: ChatMessage) -> void:
	if not _connected or _client == null:
		push_warning("[chat] dropping message: broker not connected")
		ensure_connected()
		return
	var topic := topic_for_channel(message.channel)
	if topic == "":
		push_warning("[chat] dropping message: channel %d has no topic" % message.channel)
		return
	if message.channel == DirectChat.ChannelE.DIRECT_MESSAGE:
		message.peer_id = _resolve_id(message.channel)
	message.author = Globals.player_name
	_client.publish(topic, JSON.stringify({
		"author": message.author,
		"content": message.content,
		"channel": message.channel,
	}))

## Register the id provider for a context channel. REGION/GROUP/CORPORATION take the
## context id itself (which group? which corporation?); DIRECT_MESSAGE takes the PEER's
## player id — the local id is always ours, only the other side of the conversation
## varies. An empty id simply leaves the channel inactive, which is also how a group
## left or a corporation quit takes its channel down again.
func set_id_provider(channel: int, provider: Callable) -> void:
	_id_providers[channel] = provider
	if _connected:
		_subscribe_active_channels()
	channels_changed.emit()

## Open the private conversation with [param peer_id] (a social player id): pins it as THE
## private thread, the one the message box shows and filters on.
##
## [param display_name] is what the caller already holds — the contact card carries it, so
## there is nothing to look up. Omitted, it resolves from social in the background
## (see [method resolve_peer_name]) and the bar fills in when the answer lands.
func start_dm(peer_id: String, display_name: String = "") -> void:
	peer_id = peer_id.strip_edges()
	if peer_id == "":
		return
	remember_peer_name(peer_id, display_name)
	set_id_provider(DirectChat.ChannelE.DIRECT_MESSAGE, func() -> String: return peer_id)
	# Opening the thread is what clears "has something new" — reading it is the point.
	_pending_dm_peers.erase(peer_id)
	dm_requested.emit(peer_id)
	dm_peer_changed.emit(peer_id, dm_peer_name())


## Close the private thread: the pinned bar goes away and the message box stops filtering.
func close_dm() -> void:
	if dm_peer() == "":
		return
	set_id_provider(DirectChat.ChannelE.DIRECT_MESSAGE, func() -> String: return "")
	dm_peer_changed.emit("", "")


## The pinned correspondent's social id, or "" when no private thread is open.
func dm_peer() -> String:
	return _resolve_id(DirectChat.ChannelE.DIRECT_MESSAGE)


## The pinned correspondent's display name, or "" while it is still being resolved.
func dm_peer_name() -> String:
	return display_name_of(dm_peer())


## [param peer_id]'s display name if we know it, "" otherwise. Never triggers a lookup —
## the caller decides whether a miss is worth a request (see [method resolve_peer_name]).
func display_name_of(peer_id: String) -> String:
	return str(_peer_names.get(peer_id, ""))


## Every peer we have a thread with, newest first, as {id, name, pending}. The picker in the
## message box offers exactly these: a thread the player has opened or received on.
func dm_peers() -> Array:
	var out: Array = []
	for peer_id: String in _peer_names.keys():
		out.append({
			"id": peer_id,
			"name": display_name_of(peer_id),
			"pending": _pending_dm_peers.has(peer_id),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left: bool = bool(a["pending"])
		var right: bool = bool(b["pending"])
		if left != right:
			return left
		return str(a["name"]).to_lower() < str(b["name"]).to_lower())
	return out


## Remember [param display_name] for [param peer_id]. An empty name is ignored rather than
## stored, so a later lookup can still resolve it instead of reading back "".
func remember_peer_name(peer_id: String, display_name: String) -> void:
	if peer_id == "" or display_name.strip_edges() == "":
		return
	_peer_names[peer_id] = display_name.strip_edges()
	peer_name_resolved.emit(peer_id, str(_peer_names[peer_id]))


## Look [param peer_id] up in social when its name is unknown, and announce the answer. A no-op
## when we already have one, so a peer met twice costs nothing. Safe to call on every arrival.
func resolve_peer_name(peer_id: String) -> void:
	if peer_id == "" or _peer_names.has(peer_id):
		return
	var result: Dictionary = await PlayerServices.profile_get_by_id(peer_id)
	if not bool(result.get("ok", false)):
		return
	var profile: Variant = result.get("data")
	if not (profile is Dictionary):
		return
	remember_peer_name(peer_id, str((profile as Dictionary).get("displayName", "")))


## Publish straight to [param peer_id] without pinning the thread: the contact card's own
## composer sends this way, so writing to a contact never steals the player's message box.
## [param content] blank is ignored. Returns whether it went out.
func publish_dm_to(peer_id: String, content: String) -> bool:
	peer_id = peer_id.strip_edges()
	content = content.strip_edges()
	if peer_id == "" or content == "" or not _connected or _client == null:
		return false
	var me := _my_id()
	if me == "":
		return false
	var message := ChatMessage.new(content, DirectChat.ChannelE.DIRECT_MESSAGE,
			Globals.player_name, 0.0, peer_id)
	_client.publish(dm_publish_topic(me, peer_id), JSON.stringify({
		"author": message.author,
		"content": message.content,
		"channel": message.channel,
	}))
	return true

## Channels currently usable (have a resolvable, non-empty topic). The UI greys out
## everything not in this list.
func active_channels() -> Array:
	var result: Array = []
	for channel in _STATIC_TOPICS:
		result.append(channel)
	for channel in _TOPIC_TEMPLATES:
		if _resolve_id(channel) != "":
			result.append(channel)
	if topic_for_channel(DirectChat.ChannelE.DIRECT_MESSAGE) != "":
		result.append(DirectChat.ChannelE.DIRECT_MESSAGE)
	return result

## Resolve a channel to the topic to PUBLISH on, or "" when the channel is inactive.
func topic_for_channel(channel: int) -> String:
	if _STATIC_TOPICS.has(channel):
		return _STATIC_TOPICS[channel]
	if channel == DirectChat.ChannelE.DIRECT_MESSAGE:
		var me := _my_id()
		var peer := _resolve_id(channel)
		return dm_publish_topic(me, peer) if me != "" and peer != "" else ""
	if _TOPIC_TEMPLATES.has(channel):
		var id := _resolve_id(channel)
		if id != "":
			return _TOPIC_TEMPLATES[channel] % id
	return ""

## `chat/dm/<from>/<to>` — only <from> may write it, only <to> may read it.
static func dm_publish_topic(me: String, peer: String) -> String:
	return "chat/dm/%s/%s" % [me, peer]

## The one filter covering every DM addressed to [param me] ("+" = any sender).
static func dm_subscribe_topic(me: String) -> String:
	return "chat/dm/+/%s" % me

## The sender id carried by an incoming DM topic addressed to [param me], or "" when the
## topic is not that (wrong shape, or addressed to somebody else — never trusted).
static func dm_sender_of(topic: String, me: String) -> String:
	if me == "":
		return ""
	var parts := topic.split("/")
	if parts.size() != 4 or parts[0] != "chat" or parts[1] != "dm" or parts[3] != me:
		return ""
	return parts[2]

## True when [param topic] is [param me]'s own notification feed.
static func is_my_notify_topic(topic: String, me: String) -> bool:
	return me != "" and topic == _NOTIFY_PREFIX + me

## The notification envelope published on `notify/<me>`, or {} when the payload is not a
## JSON object (the envelope is {id, type, title?, body?, data?, sentAt}).
static func parse_notification(payload: String) -> Dictionary:
	var data: Variant = JSON.parse_string(payload)
	if data is Dictionary:
		return data
	return {}

## The id this client is known by in social: the JWT `sub` when a token is present (the
## id the server reports and the broker's ACL matches on), the Horizon player id otherwise
## (token-less dev), then the locally generated uuid as a last resort.
func _my_id() -> String:
	var via_token := PlayerServices.player_id()
	if via_token != "":
		return via_token
	var agent = NetworkOrchestrator.network_agent
	if agent != null and "my_player_uuid" in agent:
		var horizon_id := str(agent.my_player_uuid)
		if horizon_id != "":
			return horizon_id
	return Globals.player_uuid

func _resolve_id(channel: int) -> String:
	if not _id_providers.has(channel):
		return ""
	var provider: Callable = _id_providers[channel]
	if not provider.is_valid():
		return ""
	return str(provider.call())

func _player_token() -> String:
	var agent = NetworkOrchestrator.network_agent
	if agent != null and "token" in agent:
		return str(agent.token)
	return ""

## Reconcile our subscriptions with the currently active channels plus the two personal
## ones (DM wildcard, notification feed): subscribe what is new, unsubscribe what no
## longer applies (a player who changed group would otherwise keep receiving the old
## group's traffic, which _channel_for_topic then silently discards).
func _subscribe_active_channels() -> void:
	if _client == null:
		return
	var me := _my_id()
	var desired: Dictionary = {}
	if me != "":
		desired[dm_subscribe_topic(me)] = true
		desired[_NOTIFY_PREFIX + me] = true
	for channel in active_channels():
		var topic := _subscribe_topic_for(channel)
		if topic != "":
			desired[topic] = true
	for topic in _subscribed_topics.keys():
		if not desired.has(topic):
			_client.unsubscribe(topic)
			_subscribed_topics.erase(topic)
	for topic in desired:
		if not _subscribed_topics.has(topic):
			_client.subscribe(topic)
			_subscribed_topics[topic] = true

## The topic to be SUBSCRIBED to for [param channel] — the publish topic everywhere
## except DM, whose one wildcard filter covers every conversation addressed to us.
func _subscribe_topic_for(channel: int) -> String:
	if channel == DirectChat.ChannelE.DIRECT_MESSAGE:
		var me := _my_id()
		return dm_subscribe_topic(me) if me != "" else ""
	return topic_for_channel(channel)

## Register the GROUP and CORPORATION providers from the caller's own social membership,
## so those channels light up with no gameplay system of their own yet. Re-run on every
## broker (re)connect and whenever a membership mutation announces itself.
func _wire_context_channels() -> void:
	if not PlayerServices.is_available():
		return
	# GROUP: the caller's one group, if any (social answers null when they have none).
	var group: Dictionary = await PlayerServices.my_group()
	_set_context_id(DirectChat.ChannelE.GROUP, _id_of(group.get("data")))
	# CORPORATION: the first corporation the caller belongs to — with several, the chat
	# sits in the first rather than asking the player which one to write in.
	var corporations: Dictionary = await PlayerServices.my_corporations()
	_set_context_id(DirectChat.ChannelE.CORPORATION, _first_row_id(corporations))

## The provider for a context channel, possibly returning "" — an empty id leaves the
## channel inactive (greyed out), which is how losing the membership takes it down.
func _set_context_id(channel: int, id: String) -> void:
	set_id_provider(channel, func() -> String: return id)

func _on_services_changed(area: String) -> void:
	if area == "groups" or area == "corporations":
		_wire_context_channels()

## The id field of a group/corporation row, whichever name the service used for it.
static func _id_of(value: Variant) -> String:
	if value is Dictionary:
		for key: String in ["id", "groupId", "corporationId"]:
			var found: Variant = (value as Dictionary).get(key)
			if found != null and str(found) != "":
				return str(found)
	return ""

## The id of the first row of a list response ({items: [...]} or a bare array), "" when
## the list is empty or the payload is something else.
static func _first_row_id(result: Dictionary) -> String:
	var data: Variant = result.get("data")
	var rows: Variant = null
	if data is Array:
		rows = data
	elif data is Dictionary and (data as Dictionary).get("items") is Array:
		rows = (data as Dictionary).get("items")
	if not (rows is Array) or (rows as Array).is_empty():
		return ""
	return _id_of((rows as Array)[0])

func _on_broker_connected() -> void:
	_connected = true
	_set_state(State.CONNECTED)
	_reconnect_delay = _RECONNECT_DELAY_MIN
	print("[chat] broker connected")
	# Contexts before the final reconcile: the providers may light up GROUP/CORPORATION,
	# whose set_id_provider() already subscribes them while connected.
	if not _contexts_wired:
		_contexts_wired = true
		PlayerServices.changed.connect(_on_services_changed)
	_wire_context_channels()
	_subscribe_active_channels()

func _on_broker_connection_failed() -> void:
	push_warning("[chat] broker connection failed (is the textchat broker running / port-forwarded?)")
	_teardown_and_retry()

func _on_broker_disconnected() -> void:
	push_warning("[chat] broker disconnected, will retry")
	_teardown_and_retry()

## Drop the dead client and schedule a retry. Freeing it matters: the addon keeps
## accepting publish() calls on a closed socket and discards them without error,
## so a client we hang on to would look alive while swallowing every message.
func _teardown_and_retry() -> void:
	_connected = false
	_subscribed_topics.clear()
	if _client != null:
		_client.queue_free()
		_client = null
	# RETRYING while a retry is actually scheduled, IDLE when chat stopped being wanted.
	_set_state(State.RETRYING if _wants_connection else State.IDLE)
	if not _wants_connection or _reconnect_timer == null:
		return
	_reconnect_timer.start(_reconnect_delay)
	_reconnect_delay = minf(_reconnect_delay * 2.0, _RECONNECT_DELAY_MAX)

func _on_reconnect_timeout() -> void:
	if _wants_connection and _client == null:
		_open_connection()

func _on_broker_message(topic: String, payload: String) -> void:
	var me := _my_id()
	if is_my_notify_topic(topic, me):
		var envelope := parse_notification(payload)
		if not envelope.is_empty():
			notification_received.emit(envelope)
		return
	var channel := _channel_for_topic(topic)
	if channel == DirectChat.ChannelE.UNSPECIFIED:
		return
	var data = JSON.parse_string(payload)
	if typeof(data) != TYPE_DICTIONARY:
		return
	# The channel comes from the TOPIC we received on, never from the payload:
	# otherwise anyone can publish on chat/general and have it render as corporation
	# chat. (The author is still payload-supplied and therefore spoofable — only
	# broker-side JWT enforcement can fix that.) For a DM the sender is read from the
	# topic itself, which the broker's ACL has already pinned to the real writer.
	var received := ChatMessage.new(
		str(data.get("content", "")),
		channel,
		str(data.get("author", "")),
		0.0
	)
	if channel == DirectChat.ChannelE.DIRECT_MESSAGE:
		received.peer_id = dm_sender_of(topic, me)
		if received.peer_id != "":
			# The wire only carries the sender's id, so this is where a correspondent met for the
			# first time gets a name. Resolving is async: the message is delivered either way and
			# the bar fills in when the answer lands.
			resolve_peer_name(received.peer_id)
			# A DM from somebody who is not the pinned correspondent is flagged, not dropped: the log
			# filters on the pinned thread, so without this it would vanish silently.
			if received.peer_id != dm_peer():
				_pending_dm_peers[received.peer_id] = true
				pending_dm_peer.emit(received.peer_id, display_name_of(received.peer_id))
	message_received.emit(received)

func _channel_for_topic(topic: String) -> int:
	for channel in _STATIC_TOPICS:
		if _STATIC_TOPICS[channel] == topic:
			return channel
	for channel in _TOPIC_TEMPLATES:
		if topic_for_channel(channel) == topic:
			return channel
	if dm_sender_of(topic, _my_id()) != "":
		return DirectChat.ChannelE.DIRECT_MESSAGE
	return DirectChat.ChannelE.UNSPECIFIED

## Parse "ws://host[:port][/path]" into {proto, host, port}. Returns {} on a
## malformed url. Any path is dropped: the MQTT addon always requests "/" and
## mosquitto upgrades on any path, so "ws://host:80/mqtt" and "ws://host:80" are
## equivalent to us — but the path has to come off before the port is read.
func _parse_broker_url(url: String) -> Dictionary:
	var sep := url.find("://")
	if sep == -1:
		return {}
	var proto := url.substr(0, sep + 3)
	var rest := url.substr(sep + 3)
	var slash := rest.find("/")
	if slash != -1:
		rest = rest.substr(0, slash)
	if rest.is_empty():
		return {}

	# A bracketed IPv6 literal ("[::1]" / "[::1]:9001") hides colons that are not
	# the port separator, so only look for one after the closing bracket.
	var search_from := 0
	if rest.begins_with("["):
		var close := rest.find("]")
		if close == -1:
			return {}
		search_from = close

	var host := rest
	var port := 443 if proto == "wss://" or proto == "ssl://" else 80
	var colon := rest.rfind(":")
	if colon > search_from:
		var port_text := rest.substr(colon + 1)
		if not port_text.is_valid_int():
			return {}
		host = rest.substr(0, colon)
		port = int(port_text)
	if host.is_empty():
		return {}
	return {"proto": proto, "host": host, "port": port}
