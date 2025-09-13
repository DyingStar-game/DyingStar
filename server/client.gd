extends Node

var player_scene_path: String = "res://scenes/normal_player/normal_player.tscn"
var ship_scene_path: String = "res://scenes/spaceship/test_spaceship/test_spaceship.tscn"

var client_peer: ENetMultiplayerPeer = null
var peer_id: int = -1

var universe_scene: Node = null
var player_instance: Node = null
var spawn_point: Vector3 = Vector3.ZERO

# For connection with Horizon server
var websocket_url = "ws://127.0.0.1:7040"
var socket = WebSocketPeer.new()
var player_entity

var planet_scene = preload("res://scenes/planet/testplanet.tscn")

const uuid_util = preload("res://addons/uuid/uuid.gd")

func _enter_tree() -> void:
	set_process(false)

func _ready() -> void:
	set_process(false)

func start_client(receveid_universe_scene: Node, ip, port) -> void:
	universe_scene = receveid_universe_scene
	var spawn_points_list: Array[Vector3] = universe_scene.spawn_points_list
	
	if spawn_points_list.size() > 0:
		spawn_point = spawn_points_list.pick_random()
	
	if Globals.playerUUID == "":
		Globals.playerUUID = uuid_util.v4()
	# client_peer = ENetMultiplayerPeer.new()
	# client_peer.create_client(ip, port)
	# universe_scene.multiplayer.multiplayer_peer = client_peer
	# peer_id = universe_scene.multiplayer.multiplayer_peer.get_unique_id()

	# initiate connection to the Horizon server
	var err = socket.connect_to_url(websocket_url)
	if err != OK:
		push_error("connect_to_url returned error: %d" % err)
		GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.CONNEXION_ERROR)
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
		GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.CONNEXION_ERROR)
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
				print("< Got text data from server: %s" % packet_text)
				var event = JSON.parse_string(packet_text)

				# Handle the event based on its type
				match event["type"]:
					"player_props":
						handle_player_props_event(event)
					"update_props":
						update_props(event)
					_:
						print("< Unknown event type: %s" % event["type"])

# < Got text data from server: 
# {
#     "planets": [
#         {
#             "name": "Sandbox",
#             "position": {
#                 "x": 15067000000,
#                 "y": 0,
#                 "z": 0
#             },
#             "rotation": {
#                 "x": 0,
#                 "y": 0,
#                 "z": 0
#             },
#             "uuid": "2c28e3fb-9ef0-45ae-ad14-dfc81a701024"
#         }
#     ],
#     "player": {
#         "name": "gergerg",
#         "position": {
#             "x": 15067000000,
#             "y": 12000,
#             "z": 0
#         },
#         "rotation": {
#             "x": 0,
#             "y": 0,
#             "z": 0
#         },
#         "uuid": "e946ee8d-737e-4577-ab11-b169991010bd"
#     },
#     "type": "player_props"
# }
			else:
				print("< Got binary data from server: %d bytes" % packet.size())

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


func handle_player_props_event(event: Dictionary) -> void:
	if event.has("player"):
		var player_data = event["player"]
		print("Player data received: %s" % player_data)
		# Here you can handle the player data, e.g., spawn the player in the game world
		# complete_client_initialization(spawn_player(player_data))


		var spawned_entity_instance = load(player_scene_path).instantiate()
		spawned_entity_instance.spawn_position = Vector3(player_data["position"]["x"], player_data["position"]["y"], player_data["position"]["z"])
		if player_data["name"] == GameOrchestrator.login_player_name:
			spawned_entity_instance.name = player_data["name"]
			spawned_entity_instance.connect("hs_client_action_move", _on_client_action_move)
		else:
			spawned_entity_instance.name = "remoteplayer" + player_data["name"]

		spawned_entity_instance.tree_entered.connect(func():
			spawned_entity_instance.owner = get_tree().current_scene
		)
		universe_scene.add_child(spawned_entity_instance)
		spawned_entity_instance.set_physics_process(false)
		if player_data["name"] == GameOrchestrator.login_player_name:
			player_entity = spawned_entity_instance

	if event.has("planets"):
		var planets_data = event["planets"]
		print("Planets data received: %s" % planets_data)
		# Here you can handle the planets data, e.g., spawn planets in the game world
		for planet in planets_data:
			print("Loading planet scene...")
			var spawnable_planet_instance = planet_scene.instantiate()
			spawnable_planet_instance.spawn_position = Vector3(planet["position"]["x"], planet["position"]["y"], planet["position"]["z"])
			spawnable_planet_instance.name = planet.name
			# get_tree().current_scene.add_child(spawnable_planet_instance, true)
			# get_tree().current_scene.call_deferred("add_child", spawnable_planet_instance, true)
			spawnable_planet_instance.tree_entered.connect(func():
				spawnable_planet_instance.owner = get_tree().current_scene
			)
			universe_scene.add_child(spawnable_planet_instance)
			spawnable_planet_instance.set_physics_process(false)


func on_connection_established() -> void:
	request_spawn()

func request_spawn() -> void:
	NetworkOrchestrator.set_player_uuid.rpc_id(1, Globals.playerUUID, GameOrchestrator.login_player_name, GameOrchestrator.requested_spawn_point)

func complete_client_initialization(entity) -> void:
	player_instance = entity
	player_instance.player_display_name = GameOrchestrator.login_player_name
	player_instance.labelPlayerName.text = player_instance.player_display_name
	player_instance.connect("client_action_requested", _on_client_action_requested)
	player_instance.direct_chat.connect("send_message", _on_message_from_player)
	player_instance.connect("hs_client_action_move", _on_client_action_move)
 
func receive_chat_message(message: ChatMessage) -> void:
	player_instance.direct_chat.receive_message_from_server(message)

func _on_client_action_requested(datas: Dictionary) -> void:
	if datas.has("action"):
		match datas["action"]:
			"spawn":
				if datas.has("entity"):
					match datas["entity"]:
						"ship":
							var spawn_position: Vector3 = datas["spawn_position"] if datas.has("spawn_position") else player_instance.global_position + Vector3(10.0,10.0,10.0)
							var spawn_rotation: Vector3 = datas["spawn_rotation"] if datas.has("spawn_rotation") else player_instance.global_transform.basis.y.normalized()
							var data =  {
								"x": spawn_position.x,
								"y": spawn_position.y,
								"z": spawn_position.z,
								"rx": spawn_rotation.x,
								"ry": spawn_rotation.y,
								"rz": spawn_rotation.z,
							}
							NetworkOrchestrator.spawn_prop.rpc_id(1, "ship",data)
						"box50cm":
							var spawn_position: Vector3 = datas["spawn_position"] if datas.has("spawn_position") else player_instance.global_position + Vector3(10.0,10.0,10.0)
							var spawn_rotation: Vector3 = datas["spawn_rotation"] if datas.has("spawn_rotation") else player_instance.global_transform.basis.y.normalized()
							var data =  {
								"x": spawn_position.x,
								"y": spawn_position.y,
								"z": spawn_position.z,
								"rx": spawn_rotation.x,
								"ry": spawn_rotation.y,
								"rz": spawn_rotation.z,
							}
							NetworkOrchestrator.spawn_prop.rpc_id(1, "box50cm", data)
						"box4m":
							var spawn_position: Vector3 = datas["spawn_position"] if datas.has("spawn_position") else player_instance.global_position + Vector3(10.0,10.0,10.0)
							var spawn_rotation: Vector3 = datas["spawn_rotation"] if datas.has("spawn_rotation") else player_instance.global_transform.basis.y.normalized()
							var data =  {
								"x": spawn_position.x,
								"y": spawn_position.y,
								"z": spawn_position.z,
								"rx": spawn_rotation.x,
								"ry": spawn_rotation.y,
								"rz": spawn_rotation.z,
							}
							NetworkOrchestrator.spawn_prop.rpc_id(1, "box4m", data)
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
	socket.send_text(JSON.stringify({
		"namespace": "movement",
		"event": "update_position", # "move_direction",
		"data": {
			"pos": {
				"x": move_direction[0],
				"y": move_direction[1]
			},
			"rot": {
				"x": move_rotation[0],
				"y": move_rotation[1],
				"z": move_rotation[2]
			}
		}
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
		# Here you can handle the player data, e.g., update the player in the game world
		# print("update global position")
		# print(player.global_position)
		player_entity.global_position = Vector3(player["pos"]["x"], player["pos"]["y"], player["pos"]["z"])
		# print(player.global_position)
		# player_entity.global_rotation = Vector3(player["rot"]["x"], player["rot"]["y"], player["rot"]["z"])
