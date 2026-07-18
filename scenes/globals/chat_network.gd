extends Node

## Dedicated MQTT transport for the in-game text chat.
##
## Single responsibility: own the broker connection, publish outgoing messages and
## re-emit incoming ones. The UI (DirectChat) binds to this; gameplay networking
## stays in NetworkOrchestrator. Clients connect DIRECTLY to the broker — the
## broker (+ JWT auth in production) is the authority for chat, not the game server.
##
## Multi-channel "sockets": GENERAL works today. REGION/GROUP/ALLIANCE/DM need a
## context id (which group? which alliance?). Those gameplay systems do not exist
## yet, so their channels stay INACTIVE until someone registers an id provider via
## set_id_provider() — then the channel subscribes and becomes selectable on its
## own, with no other change. That is the extension point for the future design.

signal message_received(message: ChatMessage)
## Emitted when the set of usable channels changes (a provider was (un)registered),
## so the UI can refresh which channels are selectable.
signal channels_changed

const _MQTT_SCENE := preload("res://addons/mqtt/mqtt.tscn")

# Default broker endpoint (local dev). Overridable via client.ini [chat] broker_url.
const _DEFAULT_BROKER_URL := "ws://127.0.0.1:9001"

# Channels reachable with a fixed topic (no context id needed).
const _STATIC_TOPICS := {
	DirectChat.ChannelE.GENERAL: "chat/general",
}

# Channels whose topic needs a context id supplied by a provider (the "sockets").
# DIRECT_MESSAGE's id is whatever the future DM system decides identifies a
# conversation (most likely the local player's uuid, so others can address them).
const _TOPIC_TEMPLATES := {
	DirectChat.ChannelE.REGION: "chat/region/%s",
	DirectChat.ChannelE.GROUP: "chat/group/%s",
	DirectChat.ChannelE.ALLIANCE: "chat/alliance/%s",
	DirectChat.ChannelE.DIRECT_MESSAGE: "chat/dm/%s",
}

# Reconnect backoff. The broker drops us for ordinary reasons (pod restart,
# network blip); without a retry the chat stays dead for the whole session and
# publishes vanish silently, because the addon's senddata() no-ops once its
# socket is null.
const _RECONNECT_DELAY_MIN := 2.0
const _RECONNECT_DELAY_MAX := 30.0

var _client: Node = null
var _connected: bool = false
# channel (int) -> Callable() returning the context id (String), or "" when none.
var _id_providers: Dictionary = {}
# Topics we hold a live subscription for, so we can drop the stale ones when a
# context id changes. Cleared on teardown: the broker session goes with it.
var _subscribed_topics: Dictionary = {}
# True once someone asked for a connection, so a retry knows chat is still wanted.
var _wants_connection: bool = false
var _reconnect_delay: float = _RECONNECT_DELAY_MIN
var _reconnect_timer: Timer = null

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

func _open_connection() -> void:
	var url := _DEFAULT_BROKER_URL
	var config := ConfigFile.new()
	if config.load("client.ini") == OK and config.has_section_key("chat", "broker_url"):
		url = str(config.get_value("chat", "broker_url", url))

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
		return
	message.author = Globals.player_name
	_client.publish(topic, JSON.stringify({
		"author": message.author,
		"content": message.content,
		"channel": message.channel,
	}))

## Register the id provider for a context channel (REGION/GROUP/ALLIANCE/DM).
## This is the extension point: call it when the matching gameplay system knows
## the player's group/alliance/region id; the channel then subscribes and shows up.
func set_id_provider(channel: int, provider: Callable) -> void:
	_id_providers[channel] = provider
	if _connected:
		_subscribe_active_channels()
	channels_changed.emit()

## Channels currently usable (have a resolvable, non-empty topic). The UI greys out
## everything not in this list.
func active_channels() -> Array:
	var result: Array = []
	for channel in _STATIC_TOPICS:
		result.append(channel)
	for channel in _TOPIC_TEMPLATES:
		if _resolve_id(channel) != "":
			result.append(channel)
	return result

## Resolve a channel to its MQTT topic, or "" when the channel is inactive.
func topic_for_channel(channel: int) -> String:
	if _STATIC_TOPICS.has(channel):
		return _STATIC_TOPICS[channel]
	if _TOPIC_TEMPLATES.has(channel):
		var id := _resolve_id(channel)
		if id != "":
			return _TOPIC_TEMPLATES[channel] % id
	return ""

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

## Reconcile our subscriptions with the currently active channels: subscribe what
## is new, unsubscribe what no longer applies (a player who changed region would
## otherwise keep receiving the old region's traffic, which _channel_for_topic
## then silently discards).
func _subscribe_active_channels() -> void:
	if _client == null:
		return
	var desired: Dictionary = {}
	for channel in active_channels():
		var topic := topic_for_channel(channel)
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

func _on_broker_connected() -> void:
	_connected = true
	_reconnect_delay = _RECONNECT_DELAY_MIN
	print("[chat] broker connected")
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
	if not _wants_connection or _reconnect_timer == null:
		return
	_reconnect_timer.start(_reconnect_delay)
	_reconnect_delay = minf(_reconnect_delay * 2.0, _RECONNECT_DELAY_MAX)

func _on_reconnect_timeout() -> void:
	if _wants_connection and _client == null:
		_open_connection()

func _on_broker_message(topic: String, payload: String) -> void:
	var channel := _channel_for_topic(topic)
	if channel == DirectChat.ChannelE.UNSPECIFIED:
		return
	var data = JSON.parse_string(payload)
	if typeof(data) != TYPE_DICTIONARY:
		return
	# The channel comes from the TOPIC we received on, never from the payload:
	# otherwise anyone can publish on chat/general and have it render as alliance
	# chat. (The author is still payload-supplied and therefore spoofable — only
	# broker-side JWT enforcement can fix that.)
	message_received.emit(ChatMessage.new(
		str(data.get("content", "")),
		channel,
		str(data.get("author", "")),
		0.0
	))

func _channel_for_topic(topic: String) -> int:
	for channel in _STATIC_TOPICS:
		if _STATIC_TOPICS[channel] == topic:
			return channel
	for channel in _TOPIC_TEMPLATES:
		if topic_for_channel(channel) == topic:
			return channel
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
