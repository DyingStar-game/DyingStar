extends Node

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

var ship_scene_path: String = "res://scenes/spaceship/test_spaceship/test_spaceship.tscn"

var client_peer: ENetMultiplayerPeer = null
var peer_id: int = -1

var universe_scene: Node = null
var player_instance: Node = null
var spawn_point: Vector3 = Vector3.ZERO

# For connection with Horizon server
var websocket_url = "ws://192.168.20.174:7040" # "ws://127.0.0.1:7040"
var socket = WebSocketPeer.new()
var player_entity
var players_list: Dictionary = {}
var props_list: Dictionary = {
	"planet": {},
	"box50cm": {},
	"box4m": {},
	"ship": {},
}
var my_player_uuid: String = ""

# var planet_scene = preload("res://scenes/planet/testplanet.tscn")
var player_scene = preload("res://scenes/normal_player/normal_player.tscn")

var preload_planet_scene = {
	"tarsis_I": preload("res://scenes/planet/tarsis_I.tscn"),
	"tarsis_II": preload("res://scenes/planet/tarsis_II.tscn"),
	"tarsis_III": preload("res://scenes/planet/tarsis_III.tscn"),
	"tarsis_IV": preload("res://scenes/planet/tarsis_IV.tscn"),
	"tarsis_V": preload("res://scenes/planet/tarsis_V.tscn"),
	"tarsis_V.I": preload("res://scenes/planet/tarsis_V.I.tscn"),
	"tarsis_V.II": preload("res://scenes/planet/tarsis_V.II.tscn"),
	"tarsis_V.III": preload("res://scenes/planet/tarsis_V.III.tscn"),
	"tarsis_V.IV": preload("res://scenes/planet/tarsis_V.IV.tscn"),
	"tarsis_V.V": preload("res://scenes/planet/tarsis_V.V.tscn"),
	"tarsis_V.VI": preload("res://scenes/planet/tarsis_V.VI.tscn"),
	"tarsis_VI": preload("res://scenes/planet/tarsis_VI.tscn"),
	"tarsis_VI.I": preload("res://scenes/planet/tarsis_VI.I.tscn"),
	"tarsis_VI.II": preload("res://scenes/planet/tarsis_VI.II.tscn"),
	"tarsis_VII": preload("res://scenes/planet/tarsis_VII.tscn"),
	"tarsis_VIII": preload("res://scenes/planet/tarsis_VIII.tscn"),
}

# on client, Horizon messages can arrives in not right order when have parent_id for players
# so we store the message in this case in the goal to process them later
var pending_messages_parenting: Array[Dictionary] = []

func _enter_tree() -> void:
	set_process(false)

func _ready() -> void:
	set_process(false)

func start_client(receveid_universe_scene: Node, _ip, _port) -> void:
	universe_scene = receveid_universe_scene
	var spawn_points_list: Array[Vector3] = universe_scene.spawn_points_list

	if spawn_points_list.size() > 0:
		spawn_point = spawn_points_list.pick_random()

	if Globals.player_uuid == "":
		Globals.player_uuid = UUID_UTIL.v4()
	# client_peer = ENetMultiplayerPeer.new()
	# client_peer.create_client(ip, port)
	# universe_scene.multiplayer.multiplayer_peer = client_peer
	# peer_id = universe_scene.multiplayer.multiplayer_peer.get_unique_id()

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
	else:
		push_error("Unable to connect (timeout or error). State: %d" % socket.get_ready_state())
		GameOrchestrator.change_game_state(GameOrchestrator.GameStates.CONNEXION_ERROR)
		set_process(false)

func _process(_delta: float) -> void:

	# Call this in `_process()` or `_physics_process()`.
	# Data transfer and state updates will only happen when calling this function.
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
				print("< Client - Got text data from server: %s" % packet_text)
				var event = JSON.parse_string(packet_text)

				if not event.has("type"):
					match event["object_type"]:
						"GorcPlayer":
							player_update(event)

					if event["event_type"] == "gorc_create":
						if event["channel"] == 0:
							create_generic_object(event["data"])

					if event["event_type"] == "gorc_update":
						if event["channel"] == 0:
							update_generic_object(event["data"])

					continue

				# Handle the event based on its type
				match event["type"]:
					"init_ack":
						# store my player uuid
						my_player_uuid = event["player_id"]
					"gorc_zone_enter":
						create_object(event)
					"gorc_zone_exit":
						delete_object(event)
					_:
						print("< Unknown event type: %s" % event["type"])
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
		print("WebSocket closed with code: %d. Clean: %s" % [code, code != -1])
		set_process(false) # Stop processing.



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
	# player_instance.connect("client_action_requested", _on_client_action_requested)
	player_instance.direct_chat.connect("send_message", _on_message_from_player)
	player_instance.connect("hs_client_action_move", _on_client_action_move)

func receive_chat_message(message: ChatMessage) -> void:
	player_instance.direct_chat.receive_message_from_server(message)

func _on_client_action_requested(datas: Dictionary) -> void:
	if datas.has("action"):
		match datas["action"]:
			"spawn":
				print("Request to spawn %s" % datas["entity"])
				socket.send_text(JSON.stringify({
					"namespace": "props",
					"event": "spawn_request",
					"data": datas,
				}))
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

func _on_client_action_pressed(action: String) -> void:
	socket.send_text(JSON.stringify({
		"namespace": "actions",
		"event": "action_pressed",
		"data": {
			"action": action,
			"uuid": player_entity.client_uuid
		},
	}))

func update_props(event: Dictionary) -> void:
	# {
	#     "planets": [],
	#     "players": [
	#         {
	#             "pos": {
	#                 "x": 15067000003.5846,
	#                 "y": 11995.8191606779,
	#                 "z": -40.632435835404
	#             },
	#             "rot": {
	#                 "x": -0.107962081094804,
	#                 "y": 0.884086148807121,
	#                 "z": -0.0912851694602036
	#             }
	#         }
	#     ],
	#     "type": "update_props"
	# }
	for player in event["players"]:
		# print("Player position update received: %s" % player)
		if player_entity != null and player_entity.client_uuid == player["uuid"]:
			if player.has("reparent"):
				var parent = _search_parent_node(player["reparent"])
				player_entity.reparent(parent)
			player_entity.position = Vector3(player["pos"]["x"], player["pos"]["y"], player["pos"]["z"])
		elif players_list.has(player["uuid"]):
			var remote_player = players_list[player["uuid"]]
			remote_player.global_position = Vector3(player["pos"]["x"], player["pos"]["y"], player["pos"]["z"])
			remote_player.global_rotation = Vector3(player["rot"]["x"], player["rot"]["y"], player["rot"]["z"])
		else:
			print("Unknown player UUID: %s" % player["uuid"])

#func update_props_position(event: Dictionary) -> void:
	# {
	#     "props": [
	#         {
	#             "pos": {
	#                 "x": 86785.5546875,
	#                 "y": 13341.7998046875,
	#                 "z": -10387.7001953125
	#             },
	#             "rot": {
	#                 "x": 0.05005964636803,
	#                 "y": -0.00235530687496,
	#                 "z": -0.00202143285424
	#             },
	#             "type": "box50cm",
	#             "uuid": "e4490a88-a58f-4968-a6e3-b9ec662c7d54"
	#         },
	#     ],
	#     "type": "props_position_update"
	# }
	# for prop in event["props"]:
	# 	# print("Prop position update received: %s" % prop)
	# 	if props_list.has(prop["type"]):
	# 		match prop["type"]:
	# 			"box50cm":
	# 				if not props_list["box50cm"].has(prop["uuid"]):
	# 					var prop_instance = box50cm_scene.instantiate()
	# 					prop_instance.tree_entered.connect(func():
	# 						prop_instance.owner = get_tree().current_scene
	# 					)
	# 					if prop.has("reparent"):
	# 						var planet = props_list["planet"][prop["reparent"]]
	# 						planet.add_child(prop_instance)
	# 					else:
	# 						universe_scene.add_child(prop_instance)

	# 					prop_instance.set_physics_process(false)
	# 					prop_instance.freeze = true
	# 					prop_instance.position = Vector3(prop["pos"]["x"], prop["pos"]["y"], prop["pos"]["z"])
	# 					prop_instance.global_rotation = Vector3(prop["rot"]["x"], prop["rot"]["y"], prop["rot"]["z"])
	# 					prop_instance.uuid = prop["uuid"]
	# 					props_list["box50cm"][prop["uuid"]] = prop_instance
	# 					NetworkOrchestrator.set_gameserver_number_boxes50cm.emit(props_list["box50cm"].size() + 1)

	# 				else:
	# 					var prop_instance = props_list["box50cm"][prop["uuid"]]
	# 					if prop.has("reparent"):
	# 						var planet = props_list["planet"][prop["reparent"]]
	# 						prop_instance.reparent(planet)

	# 					prop_instance.position = Vector3(prop["pos"]["x"], prop["pos"]["y"], prop["pos"]["z"])
	# 					prop_instance.global_rotation = Vector3(prop["rot"]["x"], prop["rot"]["y"], prop["rot"]["z"])
	# 			"planet":
	# 				if props_list["planet"].has(prop["uuid"]):
	# 					var prop_instance = props_list["planet"][prop["uuid"]]
	# 					prop_instance.global_position = Vector3(prop["pos"]["x"], prop["pos"]["y"], prop["pos"]["z"])
	# 					prop_instance.global_rotation = Vector3(prop["rot"]["x"], prop["rot"]["y"], prop["rot"]["z"])
	# 				else:
	# 					print("Unknown planet UUID: %s" % prop["uuid"])
	# 			_:
	# 				print("Unknown prop type: %s" % prop["type"])
	# 				continue
	# 	else:
	# 		print("Unknown prop type: %s" % prop["type"])

func create_object(event: Dictionary) -> void:
	match event["object_type"]:
		"GorcPlayer":
			if event["channel"] == 0:
				create_player(event)
			if event["channel"] == 2:
				set_player_name(event)

		"planet":
			create_planet(event)
		_:
			if event["channel"] == 0:
				create_generic_object(event)

func delete_object(event: Dictionary) -> void:
	match event["object_type"]:
		"GorcPlayer":
			delete_player(event)
		_:
			print("unknown object type for deletion")

func create_generic_prop(event: Dictionary) -> void:
	if event["zone_data"]["objectdef"] == "planets":
		var planet = event["zone_data"]
		print("Client: Load planet: %s" % planet)
		var planet_scene = load("res://scenes/planet/" + planet["scenename"] + ".tscn")

		var spawnable_planet_instance = planet_scene.instantiate()
		spawnable_planet_instance.spawn_position = Vector3(
			planet["position"]["x"], planet["position"]["y"], planet["position"]["z"]
		)
		spawnable_planet_instance.name = planet["name"]
		spawnable_planet_instance.uuid = planet["uuid"]
		# get_tree().current_scene.add_child(spawnable_planet_instance, true)
		# get_tree().current_scene.call_deferred("add_child", spawnable_planet_instance, true)
		spawnable_planet_instance.tree_entered.connect(func():
			spawnable_planet_instance.owner = get_tree().current_scene
		)

		universe_scene.add_child(spawnable_planet_instance)
		universe_scene.assign_spawn_informations()
		spawnable_planet_instance.set_physics_process(false)
		props_list["planet"][planet["uuid"]] = spawnable_planet_instance

func create_player(event: Dictionary) -> void:
	print("Create player: %s" % event)
	var player_data = event["zone_data"]

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
		universe_scene.add_child(spawned_entity_instance)
		spawned_entity_instance.set_physics_process(false)

		if player_data["parent_id"] != "":
			var parent = _search_parent_node(player_data["parent_id"])
			if parent != null:
				spawned_entity_instance.reparent(parent)

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

func set_player_name(event: Dictionary) -> void:
	pass
	if players_list.has(event["object_id"]):
		if event["object_id"] == my_player_uuid:
			players_list[event["object_id"]].name = event["zone_data"]["name"]
		# else:
		# 	pass
			# players_list[event["object_id"]].name = "remoteplayer" + event["zone_data"]["name"]

func create_planet(message: Dictionary) -> void:
	print("Create planet: %s" % message)

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
		var spawnable_planet_instance = preload_planet_scene[message["zone_data"]["scenename"]].instantiate()
		spawnable_planet_instance.spawn_position = Vector3(
			message["zone_data"]["position"]["x"], message["zone_data"]["position"]["y"], message["zone_data"]["position"]["z"]
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

func create_generic_object(event: Dictionary) -> void:
	print("Create generic object: %s" % event)
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
	var object_data = {}
	if event.has("zone_data"):
		object_data = event["zone_data"]
	else:
		object_data = event["object_data"]
	if not props_list.has(event["object_type"]):
		props_list[event["object_type"]] = {}
	if not props_list[event["object_type"]].has(event["object_id"]):
		var prop_scene = load("res://" + object_data["scenename"])
		var prop_instance = prop_scene.instantiate()
		prop_instance.tree_entered.connect(func():
			prop_instance.owner = get_tree().current_scene
		)
		universe_scene.add_child(prop_instance)
		prop_instance.set_physics_process(false)
		if object_data["parent_id"] != "":
			var parent = _search_parent_node(object_data["parent_id"])
			if parent != null:
				prop_instance.reparent(parent)
		prop_instance.position = Vector3(
			object_data["position"]["x"], object_data["position"]["y"], object_data["position"]["z"]
		)
		prop_instance.global_rotation = Vector3(
			object_data["rotation"]["x"], object_data["rotation"]["y"], object_data["rotation"]["z"]
		)
		#prop_instance.freeze = true
		prop_instance.uuid = event["object_id"]
		props_list[event["object_type"]][event["object_id"]] = prop_instance

func update_generic_object(event: Dictionary) -> void:
	var object_data = event["object_data"]
	if props_list.has(event["object_type"]):
		if props_list[event["object_type"]].has(event["object_id"]):
			var prop_instance = props_list[event["object_type"]][event["object_id"]]
			prop_instance.position = Vector3(
				object_data["pos"]["x"], object_data["pos"]["y"], object_data["pos"]["z"]
			)
			prop_instance.global_rotation = Vector3(
				object_data["rot"]["x"], object_data["rot"]["y"], object_data["rot"]["z"]
			)
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

func _search_parent_node(parent_id: String) -> Node:
	for proptype in props_list.keys():
		if props_list[proptype].has(parent_id):
			return props_list[proptype][parent_id]
	return null
