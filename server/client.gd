extends Node

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

var ship_scene_path: String = "res://scenes/spaceship/test_spaceship/test_spaceship.tscn"

var client_peer: ENetMultiplayerPeer = null
var peer_id: int = -1

var universe_scene: Node = null
var player_instance: Node = null
var spawn_point: Vector3 = Vector3.ZERO

# For connection with Horizon server
var websocket_url: String = "ws://127.0.0.1:7040"
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

var my_player_uuid: String = ""

var player_scene = preload("res://scenes/normal_player/normal_player.tscn")
var props_scene: Dictionary = {
	'scenes/props/StorageBoxes/container_benne_1200x240x240.tscn': preload('res://scenes/props/StorageBoxes/container_benne_1200x240x240.tscn'),
	'scenes/props/StorageBoxes/container_liquid_1200x240x240.tscn': preload('res://scenes/props/StorageBoxes/container_liquid_1200x240x240.tscn'),
	'scenes/props/StorageBoxes/container_plate_1200x240x30.tscn': preload('res://scenes/props/StorageBoxes/container_plate_1200x240x30.tscn'),
	'scenes/props/StorageBoxes/container_standard_a_1200x240x240.tscn': preload('res://scenes/props/StorageBoxes/container_standard_a_1200x240x240.tscn'),
	'scenes/props/StorageBoxes/container_standard_b_1200x240x240.tscn': preload('res://scenes/props/StorageBoxes/container_standard_b_1200x240x240.tscn'),
	'scenes/props/StorageBoxes/pallet_benne_120x80x100.tscn': preload('res://scenes/props/StorageBoxes/pallet_benne_120x80x100.tscn'),
	'scenes/props/StorageBoxes/pallet_crate_120x80x100.tscn': preload('res://scenes/props/StorageBoxes/pallet_crate_120x80x100.tscn'),
	'scenes/props/StorageBoxes/pallet_liquid_120x80x100.tscn': preload('res://scenes/props/StorageBoxes/pallet_liquid_120x80x100.tscn'),
	'scenes/props/StorageBoxes/pallet_plate_120x80x100.tscn': preload('res://scenes/props/StorageBoxes/pallet_plate_120x80x100.tscn'),
	'scenes/props/rock/rock_mining_01.tscn': preload('res://scenes/props/rock/rock_mining_01.tscn'),
	'scenes/props/testbox/box_50cm.tscn': preload('res://scenes/props/testbox/box_50cm.tscn'),
	'scenes/props/testbox/box_4m.tscn': preload('res://scenes/props/testbox/box_4m.tscn'),
	# 'scenes/props/city/sandbox_capital.tscn': preload('res://scenes/props/city/sandbox_capital.tscn'),
}

# on client, Horizon messages can arrives in not right order when have parent_id for players
# so we store the message in this case in the goal to process them later
var pending_messages_parenting: Array[Dictionary] = []
# same for generic objects
var pending_messages_generic_objects_parenting: Array[Dictionary] = []

var network_events_received: int = 0
var network_events_sent: int = 0

func _enter_tree() -> void:
	set_process(false)

func _ready() -> void:
	set_process(false)
	Performance.add_custom_monitor("network/events_received", metric_get_network_events_received)
	Performance.add_custom_monitor("network/events_sent", metric_get_network_events_sent)

func start_client(receveid_universe_scene: Node, _ip, _port) -> void:
	_load_client_ini_file()
	universe_scene = receveid_universe_scene
	var spawn_points_list: Array[Vector3] = universe_scene.spawn_points_list

	if spawn_points_list.size() > 0:
		spawn_point = spawn_points_list.pick_random()

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
	var timeout_secs := 5.0
	var deadline := Time.get_unix_time_from_system() + int(timeout_secs)
	while socket.get_ready_state() != WebSocketPeer.STATE_OPEN and Time.get_unix_time_from_system() < deadline:
		socket.poll()
		# yield a frame so we don't block the engine
		await get_tree().process_frame

	if socket.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
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
				"login": GameOrchestrator.login_player_name,
				"password": "pass"
			}
		}))
		network_events_sent += 1
	else:
		push_error("Unable to connect (timeout or error). State: %d" % socket.get_ready_state())
		GameOrchestrator.change_game_state(GameOrchestrator.GameStates.CONNEXION_ERROR)
		set_process(false)

func _load_client_ini_file() -> void:
	var config_file := ConfigFile.new()
	var err := config_file.load("client.ini")
	if err != OK:
		print("No client.ini file found, using default settings.")
		return

	if config_file.has_section_key("network", "websocket_url"):
		websocket_url = config_file.get_value("network", "websocket_url", websocket_url)

func _process(_delta: float) -> void:
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
						_:
							print("< Client - ERROR - Unknown event type: %s" % event["type"])

				elif event.has("object_type"):
					if event["object_type"] == "GorcPlayer":
						if event.has("event_type") and event["event_type"] == "gorc_zone_enter":
							create_object(event)
						# special case for player update
						player_update(event)
					elif event["event_type"] == "update_property":
						# print("< Client - Update generic object: %s" % event)
						update_generic_object(event)
					elif event["event_type"] == "gorc_zone_enter":
						create_object(event)
					else:
						print("< Client - ERROR - Unknown object_type event: %s" % event["object_type"])
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


func _search_parent_node(parent_id: String) -> Node:
	for proptype in props_list.keys():
		if props_list[proptype].has(parent_id):
			return props_list[proptype][parent_id]
	return null

########################################################################
# TODO NetworkOrchestrator calls, not sure used with new system, needed to check it
########################################################################
func on_connection_established() -> void:
	request_spawn()

func request_spawn() -> void:
	NetworkOrchestrator.set_player_uuid.rpc_id(
		1, Globals.player_uuid, GameOrchestrator.login_player_name, GameOrchestrator.requested_spawn_point
	)

func complete_client_initialization(entity) -> void:
	player_instance = entity
	player_instance.player_display_name = GameOrchestrator.login_player_name
	player_instance.label_player_name.text = player_instance.player_display_name
	player_instance.direct_chat.connect("send_message", _on_message_from_player)
	player_instance.connect("hs_client_action_move", _on_client_action_move)

func receive_chat_message(message: ChatMessage) -> void:
	player_instance.direct_chat.receive_message_from_server(message)

########################################################################
# Signal connections
########################################################################

func _on_client_action_requested(datas: Dictionary) -> void:
	if datas.has("action"):
		match datas["action"]:
			"spawn":
				# print("Request to spawn %s" % datas["entity"])
				socket.send_text(JSON.stringify({
					"namespace": "props",
					"event": "spawn_request",
					"data": datas,
				}))
				network_events_sent += 1
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

func _on_message_from_player(message: ChatMessage) -> void:
	var dictionnary_message = {
		"content": message.content,
		"author": player_instance.player_display_name,
		"channel": message.channel,
		"creation_schedule": message.creation_schedule
	}
	NetworkOrchestrator.send_chat_message_to_server.rpc_id(1, dictionnary_message)

func _on_client_action_move(move_direction: Vector2, move_rotation: Vector3) -> void:
	# print("action move")
	# print("action move: %s - %s" % [move_direction, move_rotation])
	socket.send_text(JSON.stringify({
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
	}))
	network_events_sent += 1

func _on_client_action_pressed(action: String) -> void:
	socket.send_text(JSON.stringify({
		"namespace": "actions",
		"event": "action_pressed",
		"data": {
			"action": action,
			"uuid": player_entity.client_uuid
		},
	}))
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
		"GorcPlayer":
			if event["channel"] == 0:
				create_player(event)
			# if event["channel"] == 2:
			# 	set_player_name(event)

		"planet":
			# TODO the planet creation will use the create_generic_object (modification in planet gd script needed)
			create_planet(event)
		_:
			# for all props
			create_generic_object(event)

func delete_object(event: Dictionary) -> void:
	# We delete only on the channel 6
	if event["channel"] == 6:
		match event["object_type"]:
			"GorcPlayer":
				delete_player(event)
			_:
				if props_list.has(event["object_type"]):
					var type = event["object_type"]
					if props_list[type].has(event["object_id"]):
						var prop_instance = props_list[type][event["object_id"]]
						prop_instance.queue_free()
						props_list[type].erase(event["object_id"])
						return
				print("unknown object type for deletion")

func create_player(event: Dictionary) -> void:
	# print("Create player: %s" % event)
	var player_data = {}
	
	if event.has("zone_data"):
		player_data = event["zone_data"]
	else:
		player_data = event["data"]

	# Special code because received 2 times the gorc_zone_enter for the same player (my player)
	if players_list.has(event["object_id"]):
		return

	if player_data["parent_id"] != "" and _search_parent_node(player_data["parent_id"]) == null:
		# store pending message
		pending_messages_parenting.append(event)
		print("Pending message for player %s because parent_id %s not found yet" % [event["object_id"], player_data["parent_id"]])
		return

	if event["object_id"] == my_player_uuid:
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
	else:
		# create remote player
		if not players_list.has(event["object_id"]):
			var remote_player_instance = player_scene.instantiate()
			remote_player_instance.spawn_position = Vector3(
				player_data["position"]["x"], player_data["position"]["y"], player_data["position"]["z"]
			)
			remote_player_instance.name = "remoteplayer" + event["object_id"]
			players_list[event["object_id"]] = remote_player_instance

			remote_player_instance.tree_entered.connect(func():
				remote_player_instance.owner = get_tree().current_scene
			)
			universe_scene.add_child(remote_player_instance)
			remote_player_instance.set_physics_process(false)

			var parent = _search_parent_node(player_data["parent_id"])
			remote_player_instance.reparent(parent)
			remote_player_instance.position = Vector3(
				player_data["position"]["x"], player_data["position"]["y"], player_data["position"]["z"]
			)
			remote_player_instance.client_uuid = event["object_id"]

	NetworkOrchestrator.set_gameserver_number_players.emit(players_list.size() + 1)

func create_planet(message: Dictionary) -> void:
	# print("Create planet: %s" % message)
	# {
	#     "channel": 2,
	#     "object_id": "3388a817-f3ef-421d-b10f-4325e105628e",
	#     "object_type": "planet",
	#     "player_id": "105bb18d-cce5-448c-9d76-47f3dbba762d",
	#     "timestamp": 1762005669,
	#     "type": "gorc_zone_enter",
	#     "zone_data": {
	#         "name": "Sandbox",
	#         "position": {
	#             "x": 10000000,
	#             "y": 0,
	#             "z": 0
	#         },
	#         "rotation": {
	#             "x": 0,
	#             "y": 0,
	#             "z": 0
	#         },
	#         "scenename": "tarsis_IV"
	#     }
	# }

	# Here you can handle the planets data, e.g., spawn planets in the game world
	if not props_list["planet"].has(message["object_id"]):
		# spawn planet
		var spawnable_planet_instance = load("res://" + message["zone_data"]["scenename"]).instantiate()
		spawnable_planet_instance.spawn_position = Vector3(
			message["zone_data"]["positions"][0]["x"], message["zone_data"]["positions"][0]["y"], message["zone_data"]["positions"][0]["z"]
		)
		spawnable_planet_instance.name = message["zone_data"]["name"]
		spawnable_planet_instance.uuid = message["object_id"]
		# get_tree().current_scene.add_child(spawnable_planet_instance, true)
		# get_tree().current_scene.call_deferred("add_child", spawnable_planet_instance, true)
		spawnable_planet_instance.tree_entered.connect(func():
			spawnable_planet_instance.owner = get_tree().current_scene
		)

		universe_scene.add_child(spawnable_planet_instance)
		universe_scene.assign_spawn_informations()
		spawnable_planet_instance.set_physics_process(false)
		props_list["planet"][message["object_id"]] = spawnable_planet_instance
		# planet created, now process pending messages for players waiting for this planet as parent
		for pending_message in pending_messages_parenting.duplicate():
			var pending_player_data = pending_message["zone_data"]
			if pending_player_data["parent_id"] == message["object_id"]:
				print(
					"Processing pending message for player %s now that parent_id %s is available" % [
						pending_message["object_id"],
						pending_player_data["parent_id"]
					]
				)
				create_player(pending_message)
				pending_messages_parenting.erase(pending_message)
		# planet created, now process pending messages for generic pobjects waiting for this planet as parent
		for pending_message in pending_messages_generic_objects_parenting.duplicate():
			var pending_object_data = {}
			if pending_message.has("zone_data"):
				pending_object_data = pending_message["zone_data"]
			else:
				pending_object_data = pending_message["object_data"]
			if pending_object_data["parent_id"] == message["object_id"]:
				print(
					"Processing pending message for generic object %s now that parent_id %s is available" % [
						pending_message["object_id"],
						pending_object_data["parent_id"]
					]
				)
				create_generic_object(pending_message)
				pending_messages_generic_objects_parenting.erase(pending_message)

func create_generic_object(event: Dictionary) -> void:
	# print("Create generic object: %s" % event)
	# {
	# 	"channel": 0,
	# 	"data": {
	# 		"object_data": {
	# 			"parent_id": "3388a817-f3ef-421d-b10f-4325e105628e",
	# 			"position": {
	# 				"x": -2203850,
	# 				"y": 2,
	# 				"z": 16.4841
	# 			},
	# 			"rotation": {
	# 				"x": 0,
	# 				"y": 0,
	# 				"z": 0
	# 			},
	# 			"scenename": "scenes/props/testbox/box_50cm.tscn"
	# 		},
	# 		"object_id": "4cf7f72d-ba93-4968-b7b1-9ffec31d5845",
	# 		"object_type": "box50cm",
	# 		"position": {
	# 			"x": -2203850,
	# 			"y": 2,
	# 			"z": 16.4841
	# 		}
	# 	},
	# 	"event_type": "gorc_create",
	# 	"object_id": "4cf7f72d-ba93-4968-b7b1-9ffec31d5845",
	# 	"object_type": "box50cm",
	# 	"player_id": "4cf7f72d-ba93-4968-b7b1-9ffec31d5845",
	# 	"timestamp": 1762519740
	# }
	print("Creating generic object: %s" % event)

	var object_data = {}
	if event.has("zone_data"):
		object_data = event["zone_data"]
	else:
		object_data = event["object_data"]
	if not props_list.has(event["object_type"]):
		props_list[event["object_type"]] = {}

	if event["object_type"] == "serverinfo":
		return
	elif props_list[event["object_type"]].has(event["object_id"]):
		var prop_instance = props_list[event["object_type"]][event["object_id"]]
		prop_instance.client_channel_data_update(object_data)

	else:
		# the item not exists
		if object_data.has("scenename"):
			# event has scenename, so we can create it

			if object_data.has("parent_id"):
				if object_data["parent_id"] != "" and _search_parent_node(object_data["parent_id"]) == null:
					# store pending message
					pending_messages_generic_objects_parenting.append(event)
					print("Pending message for object %s because parent_id %s not found yet" % [event["object_id"], object_data["parent_id"]])
					return

			var prop_scene: PackedScene
			if props_scene.has(object_data["scenename"]):
				prop_scene = props_scene[object_data["scenename"]]
			else:
				prop_scene = load("res://" + object_data["scenename"])
			var prop_instance = prop_scene.instantiate()
			prop_instance.tree_entered.connect(func():
				prop_instance.owner = get_tree().current_scene
			)

			if object_data.has("parent_id"):
				if object_data["parent_id"] != "":
					var parent = _search_parent_node(object_data["parent_id"])
					if parent != null:
						parent.add_child(prop_instance)
					else:
						universe_scene.add_child(prop_instance)
				else:
					universe_scene.add_child(prop_instance)
			else:
				universe_scene.add_child(prop_instance)
			prop_instance.set_physics_process(false)
			if prop_instance is RigidBody3D:
				prop_instance.freeze = true
			prop_instance.uuid = event["object_id"]

			props_list[event["object_type"]][event["object_id"]] = prop_instance

			prop_instance.client_channel_data_update(object_data)
			if props_pre_creations.has(event["object_id"]):
				for channel in props_pre_creations[event["object_id"]]["channels"]:
					prop_instance.client_channel_data_update(props_pre_creations[event["object_id"]]["channels"][channel])
				props_pre_creations.erase(event["object_id"])

			# generic object created, now process pending messages for generic objects waiting for this generic object as parent
			for pending_message in pending_messages_generic_objects_parenting.duplicate():
				var pending_object_data = {}
				if pending_message.has("zone_data"):
					pending_object_data = pending_message["zone_data"]
				else:
					pending_object_data = pending_message["object_data"]
				if pending_object_data["parent_id"] == event["object_id"]:
					print(
						"Processing pending message for generic object %s now that parent_id %s is available" % [
							pending_message["object_id"],
							pending_object_data["parent_id"]
						]
					)
					create_generic_object(pending_message)
					pending_messages_generic_objects_parenting.erase(pending_message)
		else:
			# TODO case yet created (channel 6 arrived before others), so now manage other channels
			if props_list.has(event["object_type"]) and props_list[event["object_type"]].has(event["object_id"]):
				var prop_instance = props_list[event["object_type"]][event["object_id"]]
				prop_instance.client_channel_data_update(event["data"])

			# event not has scenename, so we store it for later creation
			elif not props_pre_creations.has(event["object_id"]):
				props_pre_creations[event["object_id"]] = {
					"type": event["object_type"],
					"channels": {
						event["channel"]: object_data
					}
				}
			else:
				props_pre_creations[event["object_id"]]["channels"][event["channel"]] = object_data

func update_generic_object(event: Dictionary) -> void:
	# type of messages:
	# {
	#     "channel": 6,
	#     "data": {
	#         "blocs": [
	#             {
	#                 "fractured": false,
	#                 "keep_side": 1,
	#                 "position": 0.956444825210478,
	#                 "rotation_y": 33.6535922290459,
	#                 "rotation_z": -14.3839705151433,
	#                 "side2_uuid": ""
	#             }
	#         ],
	#         "parent_id": "3388a817-f3ef-421d-b10f-4325e105628e",
	#         "scenename": "scenes/props/rock/rock_mining_01.tscn"
	#     },
	#     "event_type": "update_property",
	#     "object_id": "cc3de01c-bfa8-40d6-8315-611dc92505ec",
	#     "object_type": "miningrock",
	#     "player_id": "cc3de01c-bfa8-40d6-8315-611dc92505ec",
	#     "timestamp": 1763283386
	# }
	if event["object_type"] == "serverinfo":
		if event["data"].has("players_number"):
			NetworkOrchestrator.set_gameserver_number_players.emit(event["data"]["players_number"])
		if event["data"].has("fps"):
			NetworkOrchestrator.set_gameserver_server_fps.emit(event["data"]["fps"])
		if event["data"].has("objects_number"):
			NetworkOrchestrator.set_gameserver_number_objects.emit(event["data"]["objects_number"])
		if event["data"].has("scenes_number"):
			NetworkOrchestrator.set_gameserver_number_scenes.emit(event["data"]["scenes_number"])
		return

	elif props_list.has(event["object_type"]):
		if props_list[event["object_type"]].has(event["object_id"]):
			var prop_instance = props_list[event["object_type"]][event["object_id"]]
			prop_instance.client_channel_data_update(event["data"])
		else:
			print("Update generic object but not found: %s" % event["object_id"])
	else:
		print("Update generic object but type not found: %s" % event["object_type"])

func delete_player(event: Dictionary) -> void:
	if not event["channel"] == 0:
		return
	if players_list.has(event["object_id"]):
		var remote_player = players_list[event["object_id"]]
		remote_player.queue_free()
		players_list.erase(event["object_id"])
		NetworkOrchestrator.set_gameserver_number_players.emit(players_list.size() + 1)
		print("Player %s has been removed." % event["object_id"])
	else:
		print("Player to delete %s not found." % event)

func player_update(message: Dictionary) -> void:
	# print("Player update: %s" % message)
	if message["channel"] == 0:
		var uuid = message["object_id"]
		if players_list.has(uuid):
			if message["event_type"] == "move":
				var player = players_list[uuid]
				player.position = Vector3(
					message["data"]["new_position"]["x"],
					message["data"]["new_position"]["y"],
					message["data"]["new_position"]["z"]
				)
		else:
			print("Update Player but not found...")

func metric_get_network_events_received():
	var result = network_events_received
	network_events_received = 0
	return result

func metric_get_network_events_sent():
	var result = network_events_sent
	network_events_sent = 0
	return result
