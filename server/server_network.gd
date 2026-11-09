extends Node

# How long a new connection has to complete its WebSocket handshake before we drop it. A port probe
# opens a TCP connection and never upgrades, so it expires here instead of stealing the link.
const CANDIDATE_TIMEOUT_S: float = 5.0

# Websocket port we will listen to (Horizon connects to it).
var port = 8980

# Our TCP Server instance.
var tcp_server = TCPServer.new()

# Our connected peers list.
var peer := WebSocketPeer.new()

# Track whether we have sent the check_server_started handshake to Horizon.
var _peer_handshake_sent: bool = false

# A connection that arrived while the current peer still looked alive, waiting to prove itself.
var _candidate: WebSocketPeer = null
var _candidate_age: float = 0.0

func _enter_tree() -> void:
	var server_ini = "server.ini"
	for argument in OS.get_cmdline_args():
		if argument.contains("srvini="):
			var key_value = argument.split("=")
			server_ini = key_value[1]
	# load port from ini
	var config = ConfigFile.new()
	config.load(server_ini)
	port = config.get_value("server", "port")

func _ready() -> void:
	set_process(false)

func start_websocket_server():
	print("Starting server socket on port %d..." % [port])
	# On Windows an IPv6 ("*") socket is IPv6-only (no dual-stack), so a locally-run dev server
	# (F5) is unreachable from Horizon, which connects over IPv4 via host.minikube.internal. Bind
	# IPv4 explicitly on Windows; keep "*" (dual-stack on Linux) for the containerised prod server.
	var bind_address: String = "0.0.0.0" if OS.get_name() == "Windows" else "*"
	var err = tcp_server.listen(port, bind_address)
	if err == OK:
		print("Server socket started.")
		set_process(true)
	else:
		push_error("Unable to start server socket.")
	return true

func _process(delta: float) -> void:
	_accept_incoming(delta)

	peer.poll()

	var peer_state := peer.get_ready_state()
	if peer_state == WebSocketPeer.STATE_OPEN:
		if not _peer_handshake_sent:
			_peer_handshake_sent = true
			var handshake = {
				"namespace": "gameserverplugin",
				"event": "check_server_started",
				"data": {}
			}
			peer.send_text(JSON.stringify(handshake))
			print("Sent check_server_started to Horizon.")
		_read_packets()


## Push out what the physics tick just queued and take in what Horizon sent, WITHOUT waiting for the
## end of the frame. send_text only queues: the bytes leave on poll(), and _process polls once per
## rendered frame. When a physics step overruns, the engine runs up to 8 catch-up steps per frame
## (5-6 frames/s on 2026-10-01): inputs then waited ~180 ms to be read and positions left in bursts
## of 4 — the lag felt while walking. server.gd calls this right after its 30 Hz send, so both
## directions keep that 30 Hz cadence whatever the frame rate. Connection handling stays in _process.
func pump() -> void:
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN or not _peer_handshake_sent:
		return
	peer.poll()
	if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_read_packets()


func _read_packets() -> void:
	while peer.get_available_packet_count():
		var packet = peer.get_packet()
		if peer.was_string_packet():
			var packet_text = packet.get_string_from_utf8()
			# print("SERVER - Received packet: %s" % [packet_text])
			var _th: int = Time.get_ticks_usec() if PropNet.prof_on else 0
			var message = JSON.parse_string(packet_text)
			if message != null:
				# Horizon's own clock, on the packet it just sent. Feeding it here rather than in
				# one handler catches EVERY message, which is what lets the estimator converge:
				# the timestamp is whole seconds, so accuracy comes from seeing many samples
				# (see Globals.sync_clock).
				if message is Dictionary and message.has("timestamp"):
					Globals.sync_clock(float(message["timestamp"]))
				dispatch_horizon_message(message)
				if PropNet.prof_on:
					_prof_horizon(message, Time.get_ticks_usec() - _th)
		else:
			print("< Got binary data from peer: %d ... echoing" % [packet.size()])
			peer.send_text(packet)


## Take whoever is knocking on the port, and hand the link to the NEWEST Horizon that proves itself.
##
## Horizon is our only client, and it reconnects by opening a fresh socket -- it never reuses the old
## one. But a Kubernetes rolling restart keeps the OUTGOING pod alive for its grace period (30 s by
## default) with its WebSocket still open, while the incoming pod is already up and, four seconds
## after booting, emits the one and only `init_server` that ships the whole world to us. While we
## only looked at new connections once the current peer read as CLOSED, that new pod sat unanswered
## in the accept queue for the whole grace period: its world dump fell on nobody, Horizon logged
## `No handlers for event: plugin:gameserverplugin:init_server` a couple of thousand times, and we
## ended up running with no props at all -- so a player spawned parented to an apartment we had
## never been told about, and could not move.
##
## A newcomer must nevertheless EARN the link: it is accepted as a candidate and only promoted once
## its WebSocket handshake completes. A port probe (the dev panel's, or anything else that just
## opens a TCP connection to see if we are alive) never upgrades, so it expires instead of cutting
## a healthy link.
func _accept_incoming(delta: float) -> void:
	if peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		if _peer_handshake_sent:  # a link that was up: say why it ended (1009 = a message over inbound_buffer_size)
			print("Horizon link closed (code %d %s)" % [peer.get_close_code(), peer.get_close_reason()])
		_peer_handshake_sent = false
		if _candidate == null and ServerNetwork.tcp_server.is_connection_available():
			# Nobody to protect: take it straight away, no probation.
			peer = _accept_stream()
			print("Peer connected (Horizon server).")
			_drain_extra()
			return

	if _candidate == null:
		if ServerNetwork.tcp_server.is_connection_available():
			_candidate = _accept_stream()
			_candidate_age = 0.0
	else:
		_candidate_age += delta
		_candidate.poll()
		var state := _candidate.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			# It spoke WebSocket, so it is a real Horizon: retire the previous one and take over.
			print("Peer connected (Horizon server), replacing the previous link.")
			peer.close()
			peer = _candidate
			_candidate = null
			_peer_handshake_sent = false
		elif state == WebSocketPeer.STATE_CLOSED or _candidate_age > CANDIDATE_TIMEOUT_S:
			_candidate.close()
			_candidate = null

	_drain_extra()


## Anything still queued beyond the one connection we are considering is backlog: refuse it now
## rather than let it pile up.
func _drain_extra() -> void:
	while ServerNetwork.tcp_server.is_connection_available():
		var extra = ServerNetwork.tcp_server.take_connection()
		extra.disconnect_from_host()


## One place to build a peer, so both paths get the same buffer sizes (they must be set BEFORE
## accept_stream) and the same no-delay setting.
func _accept_stream() -> WebSocketPeer:
	var fresh := WebSocketPeer.new()
	fresh.outbound_buffer_size = 1000000000  # 1 GB — must be set before accept_stream
	# Godot's default is 64 KiB, and a message larger than the inbound buffer closes the connection. A lava_flow
	# prop carries its checkpoint (~260 KB): Horizon's snapshot of one dropped the server every 10 s (2026-11-09).
	fresh.inbound_buffer_size = 16 * 1024 * 1024
	fresh.max_queued_packets = 1000000
	fresh.accept_stream(ServerNetwork.tcp_server.take_connection())
	fresh.set_no_delay(true)
	return fresh


func dispatch_horizon_message(message: Dictionary):
	# SERVER - Received packet:
	# {
	#     "data": {
	#         "object_data": {
	#             "name": "tarsis II",
	#             "position": {
	#                 "x": 0,
	#                 "y": 10000000,
	#                 "z": 10000000
	#             },
	#             "rotation": {
	#                 "x": 0,
	#                 "y": 0,
	#                 "z": 0
	#             },
	#             "scenename": "tarsis_II"
	#         },
	#         "object_type": "planets",
	#         "object_uuid": "6f3b006e-a6e3-493b-ba3b-57a180a09cc5"
	#     },
	#     "event": "add_prop",
	#     "namespace": "server"
	# }

	if message['namespace'] == "server":
		match message['event']:
			"add_prop":
				match message["data"]["object_type"]:
					"planet", "planets":
						# spawn planet — MUST go through create_planet (not the
						# generic path): it registers props_list["planets"], which
						# drives active-body chunk pinning. Without it the server
						# never builds terrain collision and players free-fall.
						NetworkOrchestrator.network_agent.create_planet(message)
					"player":
						NetworkOrchestrator.network_agent.create_player(message)
					_:
						NetworkOrchestrator.network_agent.create_generic_object(message)
			"update_prop":
				match message["data"]["object_type"]:
					"planet", "planets":
						NetworkOrchestrator.network_agent.update_planet(message)
					"player":
						NetworkOrchestrator.network_agent.player_action(message)
					_:
						NetworkOrchestrator.network_agent.update_generic_object(message)
			"initial_object":
				# force to pause all the objects while I load all
				# get_tree().paused = true
				match message["data"]["object_type"]:
					"planet", "planets":
						# spawn planet (see add_prop above — required for pinning)
						NetworkOrchestrator.network_agent.create_planet(message)
					"player":
						NetworkOrchestrator.network_agent.create_player(message)
					"star":
						print("Star object not yet managed")
					_:
						NetworkOrchestrator.network_agent.create_generic_object(message)
			"activate_object":
				# the switch of a hand-over: wake what initial_object created asleep, with fresh state
				NetworkOrchestrator.network_agent.activate_object(message)
			"initial_object_end":
				#  Ok let's go, unpause to begin simulation
				# get_tree().paused = false
				print("All initial objects loaded, starting simulation.")
			"freeze_object":
				# freeze object in place (in case server split)
				NetworkOrchestrator.network_agent.freeze_object(message)
			"zone":
				# zone management
				NetworkOrchestrator.network_agent.manage_zone(message)
			"prewarm":
				# players are about to arrive at these positions: load the ground first
				NetworkOrchestrator.network_agent.prewarm_chunks(message)
			"update_biome":
				# Terrain biome update (cave, road, etc.) — rebuild affected chunks
				NetworkOrchestrator.network_agent.update_planet_biome(message)
			"remove_player":
				NetworkOrchestrator.network_agent.remove_player(message)


	elif message['namespace'] == "player":
		match message['event']:
			"spawn":
				NetworkOrchestrator.network_agent.instantiate_player(message)
			"move":
				NetworkOrchestrator.network_agent.player_move(message)
			"action":
				NetworkOrchestrator.network_agent.player_action(message)

## [Perf] accounting of one Horizon message: parse + dispatch time under a key naming what it was
## (namespace/event, plus the object type or the player action name), so the proc= column of the
## [Perf] line can be attributed. 47 NPC brains chatter a lot; this says what that costs.
func _prof_horizon(message: Variant, usec: int) -> void:
	PropNet.prof_horizon_msgs += 1
	PropNet.prof_horizon_usec += usec
	var key: String = "?"
	if message is Dictionary:
		key = str(message.get("namespace", "?")) + "/" + str(message.get("event", "?"))
		var data: Variant = message.get("data")
		if data is Dictionary:
			if data.has("object_type"):
				key += "/" + str(data["object_type"])
			elif data.has("action"):
				key += "/" + str(data["action"])
	var entry: Array = PropNet.prof_horizon_by_type.get(key, [0, 0])
	entry[0] += 1
	entry[1] += usec
	PropNet.prof_horizon_by_type[key] = entry

## [param _message_type] names the message for the callers' readability (player_position, prop_update...).
func send_message(message: Dictionary, _message_type: String):
	if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		# print("server send message: ", message)
		var error = peer.send_text(JSON.stringify(message))
		if error != OK:
			printerr("Failure send message in websocket!")
			print("Failure send message in websocket!")
			print("server send message: ", message)
