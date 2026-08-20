extends Node

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")
const LIVEKIT_SCRIPT = preload("res://scenes/audio/livekit.gd")

const WEBSOCKET_CONNECT_TIMEOUT_SECS: float = 2.0
## How long a prop may sit half-received before it counts as lost rather than merely in transit. Well
## past any plausible gap between two channels of the same zone entry.
const STUCK_PROP_MS: int = 8000

var ship_scene_path: String = "res://scenes/_universe/vehicles/spaceship/test_spaceship/test_spaceship.tscn"

var client_peer: ENetMultiplayerPeer = null
var peer_id: int = -1

var universe_scene: Node = null
var player_instance: Node = null
var spawn_point: Vector3 = Vector3.ZERO

# For connection with Horizon server
var websocket_url: String = "ws://server.dyingstar-game.space:7040"
var socket := WebSocketPeer.new()
var player_entity
var players_list: Dictionary = {}
var props_list: Dictionary = {
	"planet": {},
	"box50cm": {},
	"box4m": {},
	"ship": {},
}
# We need it when a channel arrives before another in the case of this channel not have the scenename property
var props_pre_creations: Dictionary = {}
# DIAGNOSTIC (temporary): object_id -> true, so "update for an object we never built" is reported ONCE
# per object instead of tens of thousands of times. An object can go missing through two paths that
# used to be completely silent — a node freed with its parent, and a create still waiting on the
# channel that carries scenename/parent_id — which is why the log gave no clue which one it was.
var _missing_object_reported: Dictionary = {}

var my_player_uuid: String = ""
# UUIDs of all my player's ancestors (closest parent first, up to the universe
# root). Rebuilt whenever my player is (re)parented.
var my_parents_uuids: Array = []
# A zone-exit received for one of my player's ancestors: deleting it right away
# would tear my player out of the scene tree, so we stash the event here and
# flush it once my player reparents away. null when nothing is pending.
var pending_parent_delete_event = null

var player_scene = preload("res://scenes/player/player.tscn")
var props_scene: Dictionary = {
	'scenes/_universe/props/containers/container_benne_1200x240x240.tscn':
		preload('res://scenes/_universe/props/containers/container_benne_1200x240x240.tscn'),
	'scenes/_universe/props/containers/container_liquid_1200x240x240.tscn':
		preload('res://scenes/_universe/props/containers/container_liquid_1200x240x240.tscn'),
	'scenes/_universe/props/containers/container_plate_1200x240x30.tscn':
		preload('res://scenes/_universe/props/containers/container_plate_1200x240x30.tscn'),
	'scenes/_universe/props/containers/container_standard_a_1200x240x240.tscn':
		preload('res://scenes/_universe/props/containers/container_standard_a_1200x240x240.tscn'),
	'scenes/_universe/props/containers/container_standard_b_1200x240x240.tscn':
		preload('res://scenes/_universe/props/containers/container_standard_b_1200x240x240.tscn'),
	'scenes/_universe/props/containers/pallet_benne_120x80x100.tscn':
		preload('res://scenes/_universe/props/containers/pallet_benne_120x80x100.tscn'),
	'scenes/_universe/props/containers/pallet_crate_120x80x100.tscn':
		preload('res://scenes/_universe/props/containers/pallet_crate_120x80x100.tscn'),
	'scenes/_universe/props/containers/pallet_liquid_120x80x100.tscn':
		preload('res://scenes/_universe/props/containers/pallet_liquid_120x80x100.tscn'),
	# 'scenes/_universe/props/containers/pallet_plate_120x80x100.tscn':
	# 	preload('res://scenes/_universe/props/containers/pallet_plate_120x80x100.tscn'),
	'scenes/_universe/props/containers/crate_container.tscn':
		preload('res://scenes/_universe/props/containers/crate_container.tscn'),
	'scenes/_universe/props/containers/hauling_box.tscn':
		preload('res://scenes/_universe/props/containers/hauling_box.tscn'),
	'scenes/_universe/props/containers/pallet_crate.tscn':
		preload('res://scenes/_universe/props/containers/pallet_crate.tscn'),
	'scenes/_universe/props/containers/pallet_benne.tscn':
		preload('res://scenes/_universe/props/containers/pallet_benne.tscn'),
	'scenes/_universe/props/containers/pallet_liquid.tscn':
		preload('res://scenes/_universe/props/containers/pallet_liquid.tscn'),
	'scenes/_universe/props/containers/pallet_plate.tscn':
		preload('res://scenes/_universe/props/containers/pallet_plate.tscn'),
	'scenes/_universe/environment/terrain/rocks/rock_mining_sm.tscn':
		preload('res://scenes/_universe/environment/terrain/rocks/rock_mining_sm.tscn'),
	'scenes/_universe/environment/terrain/rocks/rock_mining_md.tscn':
		preload('res://scenes/_universe/environment/terrain/rocks/rock_mining_md.tscn'),
	'scenes/_universe/environment/terrain/rocks/rock_mining_lg.tscn':
		preload('res://scenes/_universe/environment/terrain/rocks/rock_mining_lg.tscn'),
	'scenes/_universe/props/containers/box_50cm.tscn':
		preload('res://scenes/_universe/props/containers/box_50cm.tscn'),
	'scenes/_universe/props/containers/box_4m.tscn':
		preload('res://scenes/_universe/props/containers/box_4m.tscn'),
	'scenes/_universe/vehicles/ground/trucks/truck.tscn':
		preload('res://scenes/_universe/vehicles/ground/trucks/truck.tscn'),
	'scenes/_universe/structures/industrial/mines/mining_depot.tscn':
		preload('res://scenes/_universe/structures/industrial/mines/mining_depot.tscn'),
	'scenes/_universe/structures/industrial/cargo_depot.tscn':
		preload('res://scenes/_universe/structures/industrial/cargo_depot.tscn'),
	# 'scenes/_universe/structures/urban/cities/sandbox_capital.tscn':
	# 	preload('res://scenes/_universe/structures/urban/cities/sandbox_capital.tscn'),
}

# on client, Horizon messages can arrives in not right order when have parent_id for players
# so we store the message in this case in the goal to process them later
var pending_messages_player_parenting: Array[Dictionary] = []
# same for generic objects
var pending_messages_generic_objects_parenting: Array[Dictionary] = []

var network_events_received: int = 0
var network_events_sent: int = 0

var token: String = ""

var check_pending_objects_timer: int = 0

func _enter_tree() -> void:
	set_process(false)

func _ready() -> void:
	set_process(false)
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--token="):
			token = arg.substr(len("--token="))
			break
	# Custom monitors are GLOBAL: a second client (back to menu -> new game) would re-register the
	# same names and leave the first one's Callable pointing at a freed node. shutdown() removes them.
	if not Performance.has_custom_monitor("network/events_received"):
		Performance.add_custom_monitor("network/events_received", metric_get_network_events_received)
	if not Performance.has_custom_monitor("network/events_sent"):
		Performance.add_custom_monitor("network/events_sent", metric_get_network_events_sent)

func start_client(receveid_universe_scene: Node, _ip, _port) -> void:
	_load_client_ini_file()
	universe_scene = receveid_universe_scene

	if Globals.player_uuid == "":
		Globals.player_uuid = UUID_UTIL.v4()

	# initiate connection to the Horizon server
	var err = socket.connect_to_url(websocket_url)
	if err != OK:
		push_error("connect_to_url returned error: %d" % err)
		GameOrchestrator.change_game_state(GameOrchestrator.GameStates.CONNEXION_ERROR)
		return

	print("Connecting to %s..." % websocket_url)
	# Poll until socket becomes OPEN (or timeout). We must poll the client so it advances states.
	var deadline := Time.get_unix_time_from_system() + int(WEBSOCKET_CONNECT_TIMEOUT_SECS)
	while socket.get_ready_state() != WebSocketPeer.STATE_OPEN and Time.get_unix_time_from_system() < deadline:
		socket.poll()
		# yield a frame so we don't block the engine
		await get_tree().process_frame

	if socket.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		remove_loading_node()
		push_error("connect_to_url returned error: %d" % err)
		GameOrchestrator.change_game_state(GameOrchestrator.GameStates.CONNEXION_ERROR)
		return

	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		print("WebSocket OPEN")
		set_process(true)
		# Initialization request to the server (player name + spawn point)
		socket.send_text(JSON.stringify({
			"namespace": "player",
			"event": "init",
			"data": {
				"token": token,
			}
		}))
		network_events_sent += 1
	else:
		remove_loading_node()
		push_error("Unable to connect (timeout or error). State: %d" % socket.get_ready_state())
		GameOrchestrator.change_game_state(GameOrchestrator.GameStates.CONNEXION_ERROR)
		set_process(false)

	# NOTE: the microphone capture is NOT set up here. It belongs to the voice client (livekit.gd),
	# the only consumer of the Record bus, which creates its own "_MicPlayer" and configures the bus
	# fully (silent send + mute). This node used to add a SECOND AudioStreamMicrophone on the very
	# same bus: two unaligned copies of the same voice summed together (~+6 dB, comb filtering) and
	# the input device stayed open even without voice chat. `audio/driver/enable_input`, which that
	# code also forced, is already set in project.godot.


func _load_client_ini_file() -> void:
	var config_file := ConfigFile.new()
	var err := config_file.load("client.ini")
	if err != OK:
		print("No client.ini file found, using default settings.")
		return

	if OS.has_feature("devmode"):
		websocket_url = "ws://localhost:7041"
	elif config_file.has_section_key("network", "websocket_url"):
		websocket_url = config_file.get_value("network", "websocket_url", websocket_url)

func _process(_delta: float) -> void:
	_report_stuck_pre_creations()
	if check_pending_objects_timer == 30:
		# every 30 frames, check pending players parenting
		for pending_message in pending_messages_player_parenting.duplicate():
			var pending_player_data = {}
			if pending_message.has("zone_data"):
				pending_player_data = pending_message["zone_data"]
			else:
				pending_player_data = pending_message["data"]
			if pending_player_data["parent_id"] != "" and _search_parent_node(pending_player_data["parent_id"]) != null:
				print(
					"Processing pending message for player %s now that parent_id %s is available" % [
						pending_message["object_id"],
						pending_player_data["parent_id"]
					]
				)
				create_player(pending_message)
				pending_messages_player_parenting.erase(pending_message)
		for pending_message in pending_messages_generic_objects_parenting.duplicate():
			var pending_object_data = {}
			if pending_message.has("zone_data"):
				pending_object_data = pending_message["zone_data"]
			else:
				pending_object_data = pending_message["object_data"]
			if pending_object_data["parent_id"] != "" and _search_parent_node(pending_object_data["parent_id"]) != null:
				print(
					"Processing pending message for generic object %s now that parent_id %s is available" % [
						pending_message["object_id"],
						pending_object_data["parent_id"]
					]
				)
				create_generic_object(pending_message)
				pending_messages_generic_objects_parenting.erase(pending_message)
		check_pending_objects_timer = 0
	else:
		check_pending_objects_timer += 1



	socket.poll()

	# get_ready_state() tells you what state the socket is in.
	var state = socket.get_ready_state()

	# `WebSocketPeer.STATE_OPEN` means the socket is connected and ready
	# to send and receive data.
	if state == WebSocketPeer.STATE_OPEN:
		while socket.get_available_packet_count():
			var packet = socket.get_packet()
			if socket.was_string_packet():
				var packet_text = packet.get_string_from_utf8()
				# print("< Client - Got text data from server: %s" % packet_text)
				network_events_received += 1
				var event = JSON.parse_string(packet_text)

				if event.has("type"):
					match event["type"]:
						"init_ack":
							# returned by Horizon server when connection established and player authenticated
							# store my player uuid
							my_player_uuid = event["player_id"]
						"gorc_zone_enter":
							# When an object enter in my zone (GorcPlayer, planet, miningrock...)
							create_object(event)
						"gorc_zone_exit":
							# When an object exit from my zone (GorcPlayer, planet, miningrock...)
							delete_object(event)
						"error":
							# when have error in server side
							push_error(event["message"])
							# close the connection
							socket.close(1000, event["message"])
							GameOrchestrator.connexion_error_message = event["message"]
							GameOrchestrator.change_game_state(GameOrchestrator.GameStates.CONNEXION_ERROR)
							return
						_:
							print("< Client - ERROR - Unknown event type: %s" % event["type"])

				elif event.has("object_type"):
					if event["object_type"] == "player":
						# Players replicate through the same generic paths as props:
						# movement via "move", gameplay properties via "update_property".
						var player_event_type = event.get("event_type", "")
						if player_event_type == "gorc_zone_enter":
							create_object(event)
						elif player_event_type == "gorc_zone_exit":
							delete_player(event)
						elif player_event_type == "move":
							player_update(event)
						elif player_event_type == "update_property":
							update_generic_object(_standardize_object(event))
					elif event["event_type"] == "update_property":
						# print("< Client - Update generic object: %s" % event)
						var new_event = _standardize_object(event)
						update_generic_object(new_event)
					elif event["event_type"] == "gorc_zone_enter":
						create_object(event)
					elif event["event_type"] == "gorc_zone_exit":
						delete_object(event)
					else:
						print("< Client - ERROR - Unknown object_type event: %s" % event["object_type"])
				elif event.has("event_type"):
					if event["event_type"]== 'livekit_token':
						vocal_manage(event)
					elif event["event_type"] == "livekit_subscribe":
						vocal_subscribe_manage(event)
						print("TODO")
					elif event["event_type"] == "livekit_unsubscribe":
						vocal_unsubscribe_manage(event)
						print("TODO")
					else:
						print("< Client - ERROR - Unknown event_type: %s" % event["event_type"])
				else:
					print("< Client - ERROR - Unknown event format: %s" % packet_text)

			else:
				print("< Client - Got binary data from server: %d bytes" % packet.size())

	# `WebSocketPeer.STATE_CLOSING` means the socket is closing.
	# It is important to keep polling for a clean close.
	elif state == WebSocketPeer.STATE_CLOSING:
		pass

	# `WebSocketPeer.STATE_CLOSED` means the connection has fully closed.
	# It is now safe to stop polling.
	elif state == WebSocketPeer.STATE_CLOSED:
		# The code will be `-1` if the disconnection was not properly notified by the remote peer.
		var code = socket.get_close_code()
		print("< Client - WebSocket closed with code: %d. Clean: %s" % [code, code != -1])
		set_process(false) # Stop processing.


func _collect_parents_uuids(node: Node) -> Array:
	# Walk up the scene tree from `node` and collect the uuid of every ancestor
	# that carries one (props expose `uuid`, players expose `client_uuid`).
	# Closest parent first, up to the universe root.
	var uuids: Array = []
	var current := node.get_parent()
	while current != null:
		if "client_uuid" in current and current.client_uuid != "":
			uuids.append(current.client_uuid)
		elif "uuid" in current and current.uuid != "":
			uuids.append(current.uuid)
		current = current.get_parent()
	return uuids

## The live node a prop/player should parent to, by uuid, or null. Skips (and cleans up) a lingering
## entry whose node was already freed — otherwise callers would reparent onto a freed instance and
## crash. Returning null there is correct: a freed parent is treated as "not known yet", so the prop
## stays where it is until a real parent resolves.
## The node a replicated `parent_id` designates, with the WORLD frame spelled out. An explicit ""
## means "no networked parent" and resolves to the universe root — a legitimate destination, not a
## failure: it is where a body that left a planet's gravity belongs. Anything else is looked up, and
## null then means "not resolvable YET" (its object has not entered our GORC zones), which is a very
## different situation and must not be silently turned into a move to the world frame.
## Props already had this distinction (see the prop path's fallback to universe_scene); players did
## not, so a player crossing into space kept its planet parent and applied world coordinates as if
## they were local to it.
func _frame_node(parent_id: String) -> Node:
	return universe_scene if parent_id == "" else _search_parent_node(parent_id)


func _search_parent_node(parent_id: String) -> Node:
	for proptype in props_list.keys():
		if props_list[proptype].has(parent_id):
			var node = props_list[proptype][parent_id]
			if is_instance_valid(node):
				return node
			props_list[proptype].erase(parent_id)
			return null
	for player_id in players_list.keys():
		if player_id == parent_id:
			var pnode = players_list[player_id]
			return pnode if is_instance_valid(pnode) else null
	return null

########################################################################
# TODO NetworkOrchestrator calls, not sure used with new system, needed to check it
########################################################################
## Full stop for this network session: leave the voice room, then close the socket. Idempotent,
## and synchronous — NetworkOrchestrator.release_network_agent() calls it right before freeing us,
## because queue_free() alone would let this node (and its LiveKitAudio child) keep processing until
## the end of the frame, still publishing the mic and still receiving voice.
func shutdown() -> void:
	set_process(false)
	# Drop the clock calibration with the session: the estimate only ever climbs (see
	# Globals.sync_clock), so carrying one authority's offset into the next would be worse than
	# starting over.
	Globals.reset_clock()
	# set_process(false) above does NOT propagate to children, so the voice client would keep
	# running its own _process. Stop it explicitly, and now rather than at the end of the frame.
	var lk: Node = get_node_or_null("LiveKitAudio")
	if lk != null and lk.has_method("shutdown"):
		lk.shutdown()
	if Performance.has_custom_monitor("network/events_received"):
		Performance.remove_custom_monitor("network/events_received")
	if Performance.has_custom_monitor("network/events_sent"):
		Performance.remove_custom_monitor("network/events_sent")
	if socket != null and socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.close(1000, "client disconnected")

## Historical public name for the same shutdown.
func disconnect_from_server() -> void:
	shutdown()

func on_connection_established() -> void:
	request_spawn()

func request_spawn() -> void:
	pass
	# NetworkOrchestrator.set_player_uuid.rpc_id(
	# 	1, Globals.player_uuid, "", GameOrchestrator.requested_spawn_point
	# )

func complete_client_initialization(entity) -> void:
	player_instance = entity
	player_instance.player_display_name = ""
	player_instance.label_player_name.text = player_instance.player_display_name
	player_instance.connect("hs_client_action_move", _on_client_action_move)
	# Chat is wired directly to the broker by the ChatNetwork autoload (see
	# direct_chat.gd / chat_network.gd) — no game-server relay here anymore.

########################################################################
# Signal connections
########################################################################

func _on_client_action_requested(datas: Dictionary) -> void:
	var message = JSON.stringify({
		"namespace": "player",
		"event": "client_action",
		"data": datas,
	})
	# print("Client action requested to server: %s" % message)
	socket.send_text(message)
	network_events_sent += 1


	# NOTE: the dev spawn wheel used to ALSO send a "props/spawn_request" straight to Horizon here,
	# which spawned the prop from data the client had chosen itself (scene, type, position, parent) —
	# the game server was never asked. Spawning now goes through the "spawn_prop" action above, like
	# every other gameplay action: the server validates the key and decides the placement.
	if datas.has("action"):
		match datas["action"]:
			"control":
				if datas.has("entity"):
					match datas["entity"]:
						"ship":
							var ship_instance_path: String = datas["entity_node"].get_path() if datas.has("entity_node") else ""
							NetworkOrchestrator.request_control.rpc_id(1, player_instance.get_path(), ship_instance_path)
			"release_control":
				if datas.has("entity"):
					match datas["entity"]:
						"ship":
							var ship_instance_path: String = datas["entity_node"].get_path() if datas.has("entity_node") else ""
							NetworkOrchestrator.request_release.rpc_id(peer_id, player_instance.get_path(), ship_instance_path)

func _on_client_action_move(move_direction: Vector2, move_rotation: Vector3) -> void:
	# print("action move")
	# print("action move: %s - %s" % [move_direction, move_rotation])
	var message = JSON.stringify({
		"namespace": "movement",
		"event": "update_velocity",
		"data": {
			"pos": {
				"x": move_direction[0],
				"y": move_direction[1]
			},
			"rot": {
				"x": move_rotation[0],
				"y": move_rotation[1],
				"z": move_rotation[2]
			},
			"uuid": player_entity.client_uuid
		},
	})
	# print("Client action move to server: %s" % message)

	socket.send_text(message)
	network_events_sent += 1

func _on_client_action_pressed(action: String) -> void:
	var message = JSON.stringify({
		"namespace": "actions",
		"event": "action_pressed",
		"data": {
			"action": action,
			"uuid": player_entity.client_uuid
		},
	})
	print("Client action pressed to server: %s" % message)

	socket.send_text(message)
	network_events_sent += 1

#########################################################################
# Horizon server messages handling
#########################################################################

func create_object(event: Dictionary) -> void:
	# message type:
	#{
	#     "channel": 0,
	#     "object_id": "dc804655-7af7-4172-9dd0-47d8497b722e",
	#     "object_type": "miningrock",
	#     "player_id": "371a6b85-d941-454a-8b91-a28eb1fbe188",
	#     "timestamp": 1763037787,
	#     "type": "gorc_zone_enter",
	#     "zone_data": {
	#         "parent_id": "3388a817-f3ef-421d-b10f-4325e105628e",
	#         "position": {
	#             "x": -2209850,
	#             "y": 1.2,
	#             "z": 46.7425
	#         },
	#         "rotation": {
	#             "x": 0,
	#             "y": 0,
	#             "z": 0
	#         }
	#     }
	# }
	match event["object_type"]:
		"player":
			if int(event["channel"]) == 0:
				create_player(event)

		"star":
			# The system star is a static node in the level (system_sandbox.tscn "Star"); ignore the
			# network duplicate, otherwise the client ends up with TWO star.tscn instances — two star
			# meshes/glows at the same spot. All code resolves the star via the level node
			# (universe_scene.get_node("Star") / _find_sun), never this networked copy.
			pass

		_:
			# for all props
			var new_event = _standardize_object(event)
			create_generic_object(new_event)

func delete_object(event: Dictionary) -> void:
	if int(event["channel"]) == 0:
		match event["object_type"]:
			"GorcPlayer":
				delete_player(event)

	# We delete only on the channel 6
	if int(event["channel"]) == 6:
		# An object that leaves is gone whether or not it ever made it into the tree: drop any
		# half-received channel data with it. Otherwise a prop that was still waiting for its
		# other channel keeps that stale half forever, and the next zone-enter merges the old
		# data into the new one.
		props_pre_creations.erase(event["object_id"])
		if props_list.has(event["object_type"]):
			var type = event["object_type"]
			if props_list[type].has(event["object_id"]):
				# If this object is one of my player's ancestors, deleting it now would rip my
				# player out of the scene tree. Defer it: keep the object and flush the delete
				# once my player has reparented away (see player_update / _flush_pending_parent_delete).
				if event["object_id"] in my_parents_uuids:
					pending_parent_delete_event = event
					return

				var prop_instance = props_list[type][event["object_id"]]
				# Already freed with a deleted parent (crate in a bed, carried item): nothing to free,
				# just drop the lingering entry. Without this the is_instance_valid() below is false, the
				# carried-object guard is skipped, and queue_free() hits a freed node → client crash.
				if not is_instance_valid(prop_instance):
					props_list[type].erase(event["object_id"])
					return
				# A carried object is parented to a player and follows it locally; its GORC zone
				# position goes stale while carried, so ignore this despawn (otherwise it vanishes
				# from the carrier's hands over distance). It is freed with its player anyway.
				if prop_instance.get_parent() is Player:
					return
				prop_instance.queue_free()
				props_list[type].erase(event["object_id"])
				return
		print("unknown object type for deletion")

func _flush_pending_parent_delete() -> void:
	print("Flushing pending parent delete event: %s" % pending_parent_delete_event)
	# Runs deferred, after my player's reparent has settled. Now that my player is no
	# longer parented to it, actually remove the object whose zone-exit we held back.
	if pending_parent_delete_event == null:
		return
	var event = pending_parent_delete_event
	# Still one of my ancestors? Then the reparent did not move us off it — keep waiting.
	if event["object_id"] in my_parents_uuids:
		return
	pending_parent_delete_event = null
	var type = event["object_type"]
	if props_list.has(type) and props_list[type].has(event["object_id"]):
		var prop_instance = props_list[type][event["object_id"]]
		if is_instance_valid(prop_instance):
			prop_instance.queue_free()
		props_list[type].erase(event["object_id"])

## Apply a player's gameplay state on the client — flashlight, equipped tool, head/helmet, carrying,
## etc. ONE shared path used both when a player is first created (late-join: the full current state
## rides the gorc_zone_enter snapshot) and on every later delta, so the two never drift. Position /
## rotation / velocity ride the dedicated "move" path, so they are skipped here. SOLID/DRY: any NEW
## whitelisted player property is covered automatically — just handle it in client_channel_data_update,
## nothing to change here.
func _apply_player_gameplay_props(player_node: Node, data: Dictionary) -> void:
	# TEMP DEBUG (dialog): pairs with the "[dialog] -> wire" print on the server. If that one fires and
	# this one never does, Horizon is dropping the property. Remove with its server-side twin.
	if data.has("conversation"):
		print("[dialog] <- horizon: ", data["conversation"], " valid_node=", is_instance_valid(player_node))
	if not is_instance_valid(player_node):
		return
	var props: Dictionary = data.duplicate()
	props.erase("position")
	props.erase("rotation")
	props.erase("velocity")
	if not props.is_empty():
		player_node.client_channel_data_update(props)

func create_player(event: Dictionary) -> void:
	# TODO have channel 0 (position , rotation) and 6 (parent_id)
	# we are here with position. rotation but not parent_id

	# print("Create player: %s" % event)
	var player_data = {}

	if event.has("zone_data"):
		player_data = event["zone_data"]
	else:
		player_data = event["data"]

	# Special code because received 2 times the gorc_zone_enter for the same player (my player)
	if players_list.has(event["object_id"]):
		# special case when parent to very far away object and have a gorc_zone_enter
		var player = players_list[event["object_id"]]
		if not is_instance_valid(player):  # freed with a deleted parent — drop the stale entry
			players_list.erase(event["object_id"])
			return
		var current_parent = player.get_parent()
		var new_parent = _search_parent_node(player_data["parent_id"])
		if current_parent == null and player_data["parent_id"] != null:
			print("case not coded")
		elif current_parent.uuid != player_data["parent_id"]:
			print("Reparenting player %s to new parent %s" % [event["object_id"], player_data["parent_id"]])
			player.reparent(new_parent)
			player.reset_physics_interpolation()
			player.net_reset_interp()
			player.position = Vector3(
				player_data["position"]["x"], player_data["position"]["y"], player_data["position"]["z"]
				)
		return

	if player_data["parent_id"] != "" and _search_parent_node(player_data["parent_id"]) == null:
		# store pending message
		pending_messages_player_parenting.append(event)
		print("Pending message for player %s because parent_id %s not found yet" % [event["object_id"], player_data["parent_id"]])
		return

	if event["object_id"] == my_player_uuid:
		# The server (Horizon) provides our display name (a generated pseudo when the
		# token is bypassed in dev). It is the single source of truth for the player
		# name — chat author, labels, HOME plates, future character screens.
		Globals.player_name = str(player_data.get("name", Globals.player_name))
		# await get_tree().create_timer(1).timeout
		var spawned_entity_instance = player_scene.instantiate()
		spawned_entity_instance.spawn_position = Vector3(
			player_data["position"]["x"], player_data["position"]["y"], player_data["position"]["z"]
		)
		spawned_entity_instance.name = my_player_uuid
		spawned_entity_instance.connect("hs_client_action_move", _on_client_action_move)
		spawned_entity_instance.connect("hs_client_action_pressed", _on_client_action_pressed)
		spawned_entity_instance.tree_entered.connect(func():
			spawned_entity_instance.owner = get_tree().current_scene
		)
		spawned_entity_instance.set_physics_process(false)

		var parented = false
		if player_data["parent_id"] != "":
			var parent = _search_parent_node(player_data["parent_id"])
			if parent != null:
				parented = true
				parent.add_child(spawned_entity_instance)

		if not parented:
			universe_scene.add_child(spawned_entity_instance)

		spawned_entity_instance.client_uuid = my_player_uuid
		spawned_entity_instance.connect("client_action_requested", _on_client_action_requested)
		player_entity = spawned_entity_instance
		players_list[event["object_id"]] = spawned_entity_instance
		# Record the uuid of each of my ancestors.
		my_parents_uuids = _collect_parents_uuids(spawned_entity_instance)
	else:
		# create remote player
		if not players_list.has(event["object_id"]):
			var remote_player_instance = player_scene.instantiate()
			remote_player_instance.spawn_position = Vector3(
				player_data["position"]["x"], player_data["position"]["y"], player_data["position"]["z"]
			)
			remote_player_instance.name = player_data["name"]
			remote_player_instance.remote_player = true
			remote_player_instance.tree_entered.connect(func():
				remote_player_instance.owner = get_tree().current_scene
			)
			remote_player_instance.set_physics_process(false)

			var parented = false
			if player_data["parent_id"] != "":
				var parent = _search_parent_node(player_data["parent_id"])
				if parent != null:
					parented = true
					parent.add_child(remote_player_instance)

			if not parented:
				universe_scene.add_child(remote_player_instance)

			remote_player_instance.client_uuid = event["object_id"]

			players_list[event["object_id"]] = remote_player_instance

	# Late-join: apply the player's CURRENT full state right after creating it (torch on, tool out,
	# helmet off, …), not just position/name/parent — the whole state rides the gorc_zone_enter
	# snapshot. Same path as the live deltas below, so future properties are covered for free.
	_apply_player_gameplay_props(players_list.get(event["object_id"], null), player_data)

	NetworkOrchestrator.set_gameserver_number_players.emit(players_list.size() + 1)

## Is this object already waiting on a missing parent? Guards the queue against duplicates now that
## repeated updates for an unbuilt object also reach the create path.
func _is_pending_generic_object(object_id: String) -> bool:
	for m in pending_messages_generic_objects_parenting:
		if str(m.get("object_id", "")) == object_id:
			return true
	return false

func create_generic_object(event: Dictionary) -> void:
	# for better readability, we store in variable couple key/values
	var object_id = event["object_id"]
	var object_type = event["object_type"]
	var object_data = event["object_data"]

	if not props_list.has(object_type):
		props_list[object_type] = {}

	# special case for serverinfo, not create object in godot for it
	if object_type == "serverinfo":
		return

	# A lingering entry may point at a FREED node: a prop parented to another object (a crate in a bed,
	# a carried item) is freed by Godot together with that parent when the parent is deleted, but only
	# the parent's own props_list entry is erased — the child's is not. Drop the stale entry so we fall
	# through to the create branch and re-instantiate it fresh, instead of touching a freed instance.
	if props_list[object_type].has(object_id) and not is_instance_valid(props_list[object_type][object_id]):
		props_list[object_type].erase(object_id)

	if props_list[object_type].has(object_id):
		var prop_instance = props_list[object_type][object_id]
		# Address the networking through the PropSync component when present; fall back to the root for
		# props not yet migrated (incremental). get_parent()/tree ops stay on the root body.
		var net = PropSync.of(prop_instance)
		if net == null:
			net = prop_instance
		# manage special case for new parent (only when it actually changes — parent_id rides the
		# 30/s zone-0 channel, so reapplying it every frame would churn the carry).
		if object_data.has("parent_id"):
			if object_data["parent_id"] != "":
				var parent = _search_parent_node(object_data["parent_id"])
				# Only reparent when the new parent is KNOWN. If it isn't resolved yet, leave the prop
				# where it is — do NOT detach a bed-riding crate just because its truck wasn't found
				# for one frame (GORC zone churn at speed), or it stops following the truck.
				if parent != null and prop_instance.get_parent() != parent:
					net.client_parent_change(parent)
			elif prop_instance.get_parent() != universe_scene:
				net.client_parent_change(universe_scene)
		#print("client_channel_data_update (1) for existing object %s" % object_id)
		net.client_channel_data_update(object_data)

	else:
		# The item does not exist yet. Merge any channel data buffered earlier so we decide
		# instantiation with the full picture (replication channels can arrive in any order).
		var merged: Dictionary = event["object_data"].duplicate()
		if props_pre_creations.has(object_id):
			for channel in props_pre_creations[object_id]["channels"]:
				merged.merge(props_pre_creations[object_id]["channels"][channel])

		# A prop is only instantiated once we have BOTH its scene (scenename) AND its
		# placement (parent_id) — these may travel on different replication channels. A
		# client that only received the data channel (e.g. between two zone distances) must
		# NOT spawn the prop at the world origin: buffer and wait for the other channel.
		if merged.has("scenename") and merged.has("parent_id"):
			props_pre_creations.erase(object_id)
			object_data = merged
			event["object_data"] = merged

			var parent = null
			if object_data["parent_id"] != "":
				parent = _search_parent_node(object_data["parent_id"])
				if parent == null:
					# parent object not created yet -> wait for it. Queued ONCE: this path is now also
					# reached from update_generic_object, which fires many times a second, and stacking
					# a duplicate per update would grow the queue without bound.
					if not _is_pending_generic_object(object_id):
						pending_messages_generic_objects_parenting.append(event)
						print("Pending message for object %s because parent_id %s not found yet" % [object_id, object_data["parent_id"]])
					return

			var prop_scene: PackedScene
			if props_scene.has(object_data["scenename"]):
				prop_scene = props_scene[object_data["scenename"]]
			else:
				prop_scene = load("res://" + object_data["scenename"])
			# A persisted prop can reference a scene that no longer exists at that path (moved/renamed
			# by the asset-taxonomy migration). Skip it instead of crashing the whole loader.
			if prop_scene == null:
				push_warning("create_generic_object: scene not found for scenename '%s' (uuid %s), skipping" \
					% [object_data["scenename"], object_id])
				return
			var prop_instance = prop_scene.instantiate()
			# Address networking via the PropSync component when present; fall back to the root
			# (incremental migration). Physics/freeze stay on the root body.
			var net = PropSync.of(prop_instance)
			if net == null:
				net = prop_instance
			prop_instance.tree_entered.connect(func():
				prop_instance.owner = get_tree().current_scene
			)

			prop_instance.set_physics_process(false)
			if prop_instance is RigidBody3D:
				prop_instance.freeze = true
			net.uuid = object_id

			# client_channel_data_update must be called before parent for the position
			net.client_channel_data_update(object_data)

			if parent != null:
				parent.add_child(prop_instance)
			else:
				# parent_id == "" -> root-level object, attach to the universe.
				universe_scene.add_child(prop_instance)

			props_list[object_type][object_id] = prop_instance

			# generic object created, now process pending messages for players waiting for this generic object as parent
			for pending_message in pending_messages_player_parenting.duplicate():
				var pending_player_data = {}
				if pending_message.has("zone_data"):
					pending_player_data = pending_message["zone_data"]
				else:
					pending_player_data = pending_message["data"]
				if pending_player_data["parent_id"] == event["object_id"]:
					print(
						"Processing pending message for player %s now that parent_id %s is available" % [
							pending_message["object_id"],
							pending_player_data["parent_id"]
						]
					)
					create_player(pending_message)
					pending_messages_player_parenting.erase(pending_message)

			# generic object created, now process pending messages for generic objects waiting for this generic object as parent
			for pending_message in pending_messages_generic_objects_parenting.duplicate():
				var pending_object_data = {}
				pending_object_data = pending_message["object_data"]
				if pending_object_data["parent_id"] == object_id:
					print(
						"Processing pending message for generic object %s now that parent_id %s is available" % [
							pending_message["object_id"],
							pending_object_data["parent_id"]
						]
					)
					pending_messages_generic_objects_parenting.erase(pending_message)
					create_generic_object(pending_message)
		else:
			# Missing scenename or parent_id: buffer THIS channel's data and wait for the
			# other channel (the merge above will then have everything to instantiate).
			if not props_pre_creations.has(object_id):
				# Nothing is logged here on purpose: waiting for the other channel is the NORMAL path,
				# and announcing it printed several hundred lines per connection — noise that buried
				# the one line that matters. Only a prop still half-received after STUCK_PROP_MS says
				# anything, and by then it never will complete (see _report_stuck_pre_creations).
				props_pre_creations[object_id] = {
					"type": object_type,
					"channels": {}
				}
			props_pre_creations[object_id]["channels"][event["channel"]] = event["object_data"]
			if not props_pre_creations[object_id].has("since"):
				props_pre_creations[object_id]["since"] = Time.get_ticks_msec()

## Names the props that are STUCK half-received, and only those.
##
## A prop needs both its scene (scenename) and its placement (parent_id), and they travel on separate
## replication channels — so being half-received is the NORMAL state for a fraction of a second, and
## logging it as it happens buries the real fault under a hundred harmless lines. What is not normal is
## being half-received minutes later: the server only sends a property when it CHANGES, and scenename
## changes exactly once, at creation, so a channel we never received is never resent. Those props are
## invisible for the rest of the session. Reported once each, when the wait stops being plausible.
func _report_stuck_pre_creations() -> void:
	var now: int = Time.get_ticks_msec()
	for object_id in props_pre_creations:
		var entry: Dictionary = props_pre_creations[object_id]
		if entry.get("reported", false) or now - int(entry.get("since", now)) < STUCK_PROP_MS:
			continue
		entry["reported"] = true
		var merged: Dictionary = {}
		for channel in entry["channels"]:
			merged.merge(entry["channels"][channel])
		var missing: Array[String] = []
		if not merged.has("scenename"):
			missing.append("scenename")
		if not merged.has("parent_id"):
			missing.append("parent_id")
		print("[client][STUCK] %s %s never received %s (has channels %s) — it will stay invisible" % [
			entry["type"], object_id, ", ".join(missing), entry["channels"].keys()
		])


func update_generic_object(event: Dictionary) -> void:
	# for better readability, we store in variable couple key/values
	var object_id = event["object_id"]
	var object_type = event["object_type"]
	var object_data = event["object_data"]

	if object_type == "serverinfo":
		if object_data.has("godotserver"):
			if object_data["godotserver"].has("players_number"):
				NetworkOrchestrator.set_gameserver_number_players.emit(object_data["godotserver"]["players_number"])
			if object_data["godotserver"].has("fps"):
				NetworkOrchestrator.set_gameserver_server_fps.emit(object_data["godotserver"]["fps"])
			if object_data["godotserver"].has("objects_number"):
				NetworkOrchestrator.set_gameserver_number_objects.emit(object_data["godotserver"]["objects_number"])
			if object_data["godotserver"].has("scenes_number"):
				NetworkOrchestrator.set_gameserver_number_scenes.emit(object_data["godotserver"]["scenes_number"])
			if object_data["godotserver"].has("zone"):
				NetworkOrchestrator.set_gameserver_coordinates.emit(object_data["godotserver"]["zone"])
			if object_data["godotserver"].has("name"):
				NetworkOrchestrator.set_gameserver_name.emit(object_data["godotserver"]["name"])
		if object_data.has("universe"):
			if object_data["universe"].has("godotservers_number"):
				NetworkOrchestrator.set_universe_servers.emit(object_data["universe"]["godotservers_number"])
			if object_data["universe"].has("players_number"):
				NetworkOrchestrator.set_universe_players.emit(object_data["universe"]["players_number"])
		return

	if object_type == "player":
		# A player is just another replicated object. Apply the gameplay properties
		# (tools, head, perforating, carrying, ...); position/rotation/velocity come
		# from the dedicated "move" path, so skip them here.
		if players_list.has(object_id):
			var player_instance = players_list[object_id]
			# The node may already be FREED while its entry lingers here (freed along with a deleted
			# parent, or a late update after delete_player). Passing a freed object to the typed
			# _apply_player_gameplay_props is rejected outright ("previously freed ... not a subclass
			# of the expected argument class"), once per update.
			# Skip the update, but do NOT erase the entry: player_update() reads the same dictionary
			# and treats a MISSING own player as fatal ("my player deleted on client side: 7001" ->
			# CONNEXION_ERROR -> the client drops the session). Removing entries is delete_player's
			# job; a read path must never shrink the roster.
			if not is_instance_valid(player_instance):
				return
			_apply_player_gameplay_props(player_instance, object_data)
		else:
			print("Update player property but player not found: %s" % object_id)
		return

	if props_list.has(object_type):
		if props_list[object_type].has(object_id):
			var prop_instance = props_list[object_type][object_id]
			# The node may already be FREED while its entry lingers here: a prop parented to another
			# object (a crate in a truck bed, a carried item) is freed by Godot together with that
			# parent when the parent is deleted, but only the PARENT's own props_list entry is erased —
			# the child's is not. A late update for the child then lands on a freed instance. Drop the
			# stale entry and bail (a later create re-instantiates it fresh if it comes back).
			if not is_instance_valid(prop_instance):
				# DIAGNOSTIC: this erase was silent, and it is the point of no return — nothing ever
				# re-creates the object afterwards, so every later update just prints "not found".
				print("[diag] prop %s (%s) was FREED (parent deleted?) — dropping its entry" \
						% [object_id, object_type])
				props_list[object_type].erase(object_id)
				return
			# Address networking via the PropSync component when present; fall back to the root
			# (incremental migration). get_parent()/tree ops stay on the root body.
			var net = PropSync.of(prop_instance)
			if net == null:
				net = prop_instance
			# Reparent ONLY when the parent actually changes. parent_id rides zone 0 (30/s), so without
			# this guard we'd reparent every prop every frame (spam + churn that fights the carry).
			if object_data.has("parent_id"):
				if object_data["parent_id"] != "":
					var parent = _search_parent_node(object_data["parent_id"])
					if parent != null and prop_instance.get_parent() != parent:
						net.client_parent_change(parent)
				elif prop_instance.get_parent() != universe_scene:
					# parent_id "" -> dropped to the world root. Reparent, else it stays stuck under
					# its old parent (truck/player) on the client (it was never moved back).
					net.client_parent_change(universe_scene)

			#print("client_channel_data_update (5) for existing object %s" % object_id)
			net.client_channel_data_update(object_data)
		else:
			# DIAGNOSTIC: once per object (this used to fire tens of thousands of times), and now says
			# WHY — still buffered waiting for a channel, still queued on a missing parent, or neither
			# (i.e. it was created and then lost).
			if not _missing_object_reported.has(object_id):
				_missing_object_reported[object_id] = true
				var state := "unknown (created then lost?)"
				if props_pre_creations.has(object_id):
					state = "buffered in props_pre_creations, channels=%s" \
							% str(props_pre_creations[object_id]["channels"].keys())
				else:
					for m in pending_messages_generic_objects_parenting:
						if m.get("object_id", "") == object_id:
							state = "queued on missing parent %s" % m["object_data"].get("parent_id", "?")
							break
				print("[diag] Update for unbuilt object %s (%s) — %s" % [object_id, object_type, state])
			# An update carries genuine replicated data — for a vehicle that includes `scenename`
			# (see addons/dyingstar/network_defs.json). Dropping it is a POINT OF NO RETURN: a client
			# rebuild wipes props_pre_creations while Horizon, which already sent the gorc_zone_enter,
			# never replays it, so the object can only ever be described by updates from then on. Feed
			# it back through the create path, which either completes the object or re-buffers it.
			create_generic_object(event)
	else:
		print("Update generic object but type not found: %s" % object_type)

func delete_player(event: Dictionary) -> void:
	if not int(event["channel"]) == 0:
		return
	if players_list.has(event["object_id"]):
		var remote_player = players_list[event["object_id"]]
		players_list.erase(event["object_id"])
		if is_instance_valid(remote_player):  # may already be freed with a deleted parent
			remote_player.queue_free()
		NetworkOrchestrator.set_gameserver_number_players.emit(players_list.size() - 1)
		print("Player %s has been removed." % event["object_id"])
	else:
		print("Player to delete %s not found." % event)

func player_update(message: Dictionary) -> void:
	# Player movement only (position/rotation/parenting). Gameplay properties are
	# replicated through the unified update_generic_object() path, like any prop.
	if int(message["channel"]) == 0:
		var uuid = message["object_id"]
		if players_list.has(uuid):
			if message["event_type"] == "move":
				var player = players_list[uuid]
				if not is_instance_valid(player):
					players_list.erase(uuid)
					return
				var ppos := Vector3(
					message["data"]["position"]["x"],
					message["data"]["position"]["y"],
					message["data"]["position"]["z"]
				)
				if uuid == my_player_uuid:
					if message["data"].has("parent_id"):
						var parent = _frame_node(message["data"]["parent_id"])
						if parent == null:
							# The server declared a frame we cannot resolve (its object has not entered
							# our GORC zones yet). We keep our current parent but apply a position
							# measured in the DECLARED one: from here on our frame silently disagrees
							# with the server's. The server only re-declares on change, so this does not
							# self-heal — see the known-gap note in this lot.
							var held_by: String = player.get_parent().name if player.get_parent() != null else "<none>"
							push_warning("[client] my player: unresolved parent_id %s, staying under '%s' — frame now diverges from the server"
									% [message["data"]["parent_id"], held_by])
						elif player.get_parent() != parent:
							player.reparent(parent)
							player.reset_physics_interpolation()
							player.net_reset_interp()
							# Rare event (teleporter / cross-zone) — worth a trace.
							print("[client] server reparent -> %s at local (%.0f, %.0f, %.0f)"
									% [parent.name, ppos.x, ppos.y, ppos.z])
							# We just left our previous parent. If a former ancestor had a deferred
							# zone-exit, flush it next frame (deferred so the reparent settles first).
							if pending_parent_delete_event != null:
								call_deferred("_flush_pending_parent_delete")
						# Reinit the list with the uuid of each of my new ancestors.
						my_parents_uuids = _collect_parents_uuids(player)
					player.net_set_local_target(ppos)
				else:
					# Remote player: smooth it (entity interpolation) instead of teleporting at 30 Hz.
					var prot := Vector3(
						message["data"]["rotation"]["x"],
						message["data"]["rotation"]["y"],
						message["data"]["rotation"]["z"]
					)
					if message["data"].has("parent_id"):
						var parent = _frame_node(message["data"]["parent_id"])
						if parent == null:
							push_warning("[client] player %s: unresolved parent_id %s — its frame now diverges from the server"
									% [uuid, message["data"]["parent_id"]])
						elif player.get_parent() != parent:
							player.reparent(parent)
							player.reset_physics_interpolation()
							player.net_reset_interp()
					player.net_set_target(ppos, prot)
		else:
			print("Update Player but not found...")
			if uuid == my_player_uuid:
				print("My player seems deleted...")
				# Disconnect from server with error
				push_error("Fatal error, my player deleted on client side: 7001")
				GameOrchestrator.change_game_state(GameOrchestrator.GameStates.CONNEXION_ERROR)


func metric_get_network_events_received():
	var result = network_events_received
	network_events_received = 0
	return result

func metric_get_network_events_sent():
	var result = network_events_sent
	network_events_sent = 0
	return result

func vocal_manage(event: Dictionary) -> void:
	if get_node_or_null("LiveKitAudio") != null:
		print("[livekit] Already connected, ignoring duplicate token")
		return
	# Message type:
	# {
	#   "event_type": "livekit_token",
	#   "livekit_url": "ws://192.168.49.2:30188",
	#   "room": "global_room",
	#   "token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJleHAdWxsfQ.wzK7yErqGvFxZroIYXiy35cNaQ9R02gTpppk-hTLx5k"
	# }
	var livekit_node := LIVEKIT_SCRIPT.new()
	livekit_node.name = "LiveKitAudio"
	livekit_node.livekit_url = event["livekit_url"]
	livekit_node.livekit_token = event["token"]
	add_child(livekit_node)

func vocal_subscribe_manage(event: Dictionary) -> void:
	var lk: Node = get_node_or_null("LiveKitAudio")
	if lk == null:
		return
	var uuid: String = event.get("participant_uuid", event.get("player_id", ""))
	if uuid == "":
		push_warning("[client] livekit_subscribe: missing participant_uuid")
		return
	lk.map_participant_to_player(event["participant_uuid"], event["player_id"])
	lk.subscribe_participant(uuid)

func vocal_unsubscribe_manage(event: Dictionary) -> void:
	var lk: Node = get_node_or_null("LiveKitAudio")
	if lk == null:
		return
	var uuid: String = event.get("participant_uuid", event.get("player_id", ""))
	if uuid == "":
		push_warning("[client] livekit_unsubscribe: missing participant_uuid")
		return
	lk.unsubscribe_participant(uuid)

func _standardize_object(event: Dictionary) -> Dictionary:
	var channel = 0
	var object_id = ""
	var object_type = ""
	var player_id = ""
	var timestamp = 0

	if event.has("channel"):
		channel = event["channel"]
	else:
		print("ERROR: event has no channel field: %s" % event)

	if event.has("object_id"):
		object_id = event["object_id"]
	else:
		print("ERROR: event has no object_id field: %s" % event)

	if event.has("object_type"):
		object_type = event["object_type"]
	else:
		print("ERROR: event has no object_type field: %s" % event)

	if event.has("player_id"):
		player_id = event["player_id"]
	else:
		print("ERROR: event has no player_id field: %s" % event)

	if event.has("timestamp"):
		timestamp = event["timestamp"]
		# The SAME clock the game server calibrates on (see ServerNetwork), so both sides derive the
		# celestial positions from one shared instant instead of from two Windows clocks that merely
		# happen to be close. Nothing else about time crosses the network.
		Globals.sync_clock(float(timestamp))
	else:
		print("ERROR: event has no timestamp field: %s" % event)

	var new_event = {
		"channel": channel,
		"object_id": object_id,
		"object_type": object_type,
		"player_id": player_id,
		"timestamp": timestamp,
		"object_data": {},
	}
	if event.has("zone_data"):
		new_event["object_data"] = event["zone_data"]
	elif event.has("object_data"):
		new_event["object_data"] = event["object_data"]
	elif event.has("data"):
		if event["data"].has("object_data"):
			new_event["object_data"] = event["data"]["object_data"]
		else:
			new_event["object_data"] = event["data"]
	else:
		print("ERROR: event has no data field: %s" % event)

	return new_event

func remove_loading_node():
	var loading_node = get_tree().root.get_node("Loading")
	if loading_node:
		loading_node.queue_free()
