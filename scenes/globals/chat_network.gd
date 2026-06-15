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
const _TOPIC_TEMPLATES := {
	DirectChat.ChannelE.REGION: "chat/region/%s",
	DirectChat.ChannelE.GROUP: "chat/group/%s",
	DirectChat.ChannelE.ALLIANCE: "chat/alliance/%s",
}

var _client: Node = null
var _connected: bool = false
# channel (int) -> Callable() returning the context id (String), or "" when none.
var _id_providers: Dictionary = {}

## Connect to the broker if not already connecting/connected. Safe to call many
## times. No-op on the headless dedicated server (chat is a client feature).
func ensure_connected() -> void:
	if OS.has_feature("dedicated_server"):
		return
	if _client != null:
		return

	var url := _DEFAULT_BROKER_URL
	var config := ConfigFile.new()
	if config.load("client.ini") == OK and config.has_section_key("chat", "broker_url"):
		url = str(config.get_value("chat", "broker_url", url))

	_client = _MQTT_SCENE.instantiate()
	add_child(_client)
	_client.received_message.connect(_on_broker_message)
	_client.broker_connected.connect(_on_broker_connected)
	_client.broker_connection_failed.connect(_on_broker_connection_failed)

	# Auth: reuse the game JWT (set on the client network agent from --token=).
	# The broker is anonymous in local dev, so an empty token is fine for now.
	var token := _player_token()
	if token != "":
		_client.user = Globals.player_uuid if Globals.player_uuid != "" else "player"
		_client.pswd = token
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

func _subscribe_active_channels() -> void:
	for channel in active_channels():
		var topic := topic_for_channel(channel)
		if topic != "":
			_client.subscribe(topic)

func _on_broker_connected() -> void:
	_connected = true
	print("[chat] broker connected")
	_subscribe_active_channels()

func _on_broker_connection_failed() -> void:
	_connected = false
	push_warning("[chat] broker connection failed (is the textchat broker running / port-forwarded?)")

func _on_broker_message(topic: String, payload: String) -> void:
	var channel := _channel_for_topic(topic)
	if channel == DirectChat.ChannelE.UNSPECIFIED:
		return
	var data = JSON.parse_string(payload)
	if typeof(data) != TYPE_DICTIONARY:
		return
	message_received.emit(ChatMessage.new(
		str(data.get("content", "")),
		int(data.get("channel", channel)),
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

## Parse "ws://host:port" into {proto, host, port}. Returns {} on a malformed url.
func _parse_broker_url(url: String) -> Dictionary:
	var sep := url.find("://")
	if sep == -1:
		return {}
	var proto := url.substr(0, sep + 3)
	var rest := url.substr(sep + 3)
	var colon := rest.rfind(":")
	if colon == -1:
		return {}
	return {
		"proto": proto,
		"host": rest.substr(0, colon),
		"port": int(rest.substr(colon + 1)),
	}
