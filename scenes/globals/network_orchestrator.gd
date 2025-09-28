extends Node

signal set_gameserver_name(server_name)
signal set_player_global_position(pos, rot)
signal set_gameserver_number_players(number_players_server)
signal set_gameserver_number_servers(nb_servers)
signal set_gameserver_number_players_universe(nb_players)
signal set_gameserver_serverzone(serverzone)
signal set_gameserver_number_boxes50cm(number_boxes_server)

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

var sdo_server_url = ""
var server_name = ""
var server_ip = ""
var server_port = ""
var is_sdo_active = false

var server_mqtt_url
var server_mqtt_port
var server_mqtt_username
var server_mqtt_password
var server_mqtt_verbose_level

var server_sdo_url = ""
var server_sdo_port = 7050
var server_sdo_username = ""
var server_sdo_password = ""
var server_sdo_verbose_level = 2

var metrics_enabled = false
var metrics_url = ""
var metrics_port = 7050
var metrics_username = ""
var metrics_password = ""
var metrics_verbose_level = 2

var mqtt = preload("res://addons/mqtt/mqtt.tscn")
var mqtt_client
var mqtt_client_sdo
var mqtt_client_metrics

var network_agent: Node = null
var universe_scene: Node = null

var small_props_spawner_node: MultiplayerSpawner = null
var small_spawnable_props: Array[PackedScene] = []
var small_spawnable_props_entry_point: Node = null

var universe_datas_spawner_node: MultiplayerSpawner = null
var spawnable_planet_scene: PackedScene = preload("res://scenes/planet/testplanet.tscn")
var spawnable_station_scene: PackedScene = null

var players: Dictionary[int, Player] = {}
var player_ship: Dictionary[int, Spaceship] = {}

var is_inside_box4m: bool = false

var server_sdo_id = 0
var players_list = {}
var servers_list = {}
var props_list = {
	"box50cm": {},
	"box4m": {},
	"ship": {}
}

var client_change_server = null

var player_scene_path: String = "res://scenes/normal_player/normal_player.tscn"
var ship_scene_path: String = "res://scenes/spaceship/test_spaceship/test_spaceship.tscn"

func _enter_tree() -> void:
	pass

func create_server() -> void:
	network_agent = load("res://server/server.tscn").instantiate()
	call_deferred("add_child", network_agent)

func create_client() -> void:
	network_agent = load("res://server/client.tscn").instantiate()
	call_deferred("add_child", network_agent)

func start_server(changed_scene) -> Node:

	universe_scene = changed_scene

	# small_props_spawner_node = universe_scene.get_node("SmallPropsMultiplayerSpawner")
	# universe_datas_spawner_node = universe_scene.get_node("UniversDatasMultiplayerSpawner")

	#var spawnable_planet_path: String = universe_datas_spawner_node.get_spawnable_scene(0)
	#spawnable_planet_scene = load(spawnable_planet_path)
	#var spawnable_station_path: String = universe_datas_spawner_node.get_spawnable_scene(1)
	#spawnable_station_scene = load(spawnable_station_path)

	#small_props_spawner_node.spawn_function = Callable(self, "_spawn_entity")

	#preload_small_props(small_props_spawner_node)
	#small_spawnable_props_entry_point = small_props_spawner_node.get_node(small_props_spawner_node.get_spawn_path())
	network_agent.start_server(changed_scene)
	return network_agent

func start_client(changed_scene, ip = "127.0.0.1", port = 7051, server_changes: bool = false) -> Node:
	if not server_changes:
		universe_scene = changed_scene
		#small_props_spawner_node = universe_scene.get_node("SmallPropsMultiplayerSpawner")
		#
		#small_props_spawner_node.spawn_function = Callable(self, "_spawn_entity")
		#
		#small_props_spawner_node.connect("spawned", _on_entity_spawned)
	#
		#multiplayer.connected_to_server.connect(_client_connected_to_server)
		#multiplayer.server_disconnected.connect(_client_disconnected_server)
#
		#preload_small_props(small_props_spawner_node)
		#small_spawnable_props_entry_point = small_props_spawner_node.get_node(small_props_spawner_node.get_spawn_path())

	network_agent.start_client(changed_scene, ip, port)
	return network_agent

## Load configuration from server.ini file
func load_server_config():
	var config = ConfigFile.new()
	var server_ini = "server.ini"
	for argument in OS.get_cmdline_args():
		if argument.contains("srvini="):
			var key_value = argument.split("=")
			server_ini = key_value[1]
	print("Load server config file: " + server_ini)
	config.load(server_ini)
	server_ip = config.get_value("server", "ip_public")
	server_port = config.get_value("server", "port")
	server_name = config.get_value("server", "name")
	# Load SDO config
	server_sdo_url = config.get_value("server", "sdo_url")
	server_sdo_port = int(config.get_value("server", "sdo_port"))
	server_sdo_username = config.get_value("server", "sdo_username")
	server_sdo_password = config.get_value("server", "sdo_password")
	server_sdo_verbose_level = config.get_value("server", "sdo_verbose_level")
	# Load chat config
	server_mqtt_url = config.get_value("chat", "url")
	server_mqtt_port = config.get_value("chat", "port")
	server_mqtt_username = config.get_value("chat", "username")
	server_mqtt_password = config.get_value("chat", "password")
	server_mqtt_verbose_level = config.get_value("chat", "verbose_level")
	# Load metric config
	metrics_enabled = config.get_value("metrics", "enabled")
	metrics_url = config.get_value("metrics", "url")
	metrics_port = config.get_value("metrics", "port")
	metrics_username = config.get_value("metrics", "username")
	metrics_password = config.get_value("metrics", "password")
	metrics_verbose_level = config.get_value("metrics", "verbose_level")


func preload_small_props(small_props_spawner: Node) -> void:
	var small_props_number: int = small_props_spawner.get_spawnable_scene_count()
	for i in range(small_props_number):
		small_spawnable_props.append(load(small_props_spawner.get_spawnable_scene(i)))

func _spawn_entity(datas: Dictionary) -> Node:
	var spawned_entity_instance: Node3D = null
	if datas.has("entity"):
		match datas["entity"]:
			"player":
				spawned_entity_instance = load(datas["player_scene_path"]).instantiate()
				spawned_entity_instance.name = datas["player_name"]
				spawned_entity_instance.spawn_position = datas["player_spawn_position"]
				spawned_entity_instance.spawn_up = datas["player_spawn_up"]
				spawned_entity_instance.set_multiplayer_authority(datas["authority_peer_id"])

			"ship":
				spawned_entity_instance = load(datas["ship_scene_path"]).instantiate()
				spawned_entity_instance.spawn_position = datas["ship_spawn_position"]
				spawned_entity_instance.spawn_rotation = datas["ship_spawn_rotation"]
				spawned_entity_instance.set_multiplayer_authority(1)

	return spawned_entity_instance

func _on_entity_spawned(entity: Node) -> void:
	if entity is Player:
		var my_unique_id = universe_scene.multiplayer.get_unique_id()
		if entity.get_multiplayer_authority() == my_unique_id:
			network_agent.complete_client_initialization(entity)

func update_all_text_client():
	get_gameserver_number_players.rpc(network_agent.players_list.size())
	get_server_name.rpc(server_name)
	get_gameserver_number_servers.rpc(servers_list.size())
	get_gameserver_number_players_universe.rpc(players_list.size() + network_agent.players_list.size())
	get_gameserver_serverzone.rpc(network_agent.server_zone)

###################
# Chat part       #

func connect_chat_mqtt():
	mqtt_client = mqtt.instantiate()
	GameOrchestrator.get_tree().get_current_scene().add_child(mqtt_client)

	mqtt_client.broker_connected.connect(_on_mqtt_broker_connected)
	mqtt_client.broker_connection_failed.connect(_on_mqtt_broker_connection_failed)
	mqtt_client.received_message.connect(_on_mqtt_received_message)
	mqtt_client.verbose_level = server_mqtt_verbose_level
	#mqtt_client.connect_to_broker("tcp://", "192.168.20.158", 1883)
	mqtt_client.connect_to_broker("ws://", server_mqtt_url, server_mqtt_port)

func _on_mqtt_received_message(topic, message):
	if topic == "chat/GENERAL":
		var chat_data = JSON.parse_string(message)
		var chat_message = ChatMessage.new(chat_data.msg, 0, chat_data.pseudo, 0.0)
		var chat_message_for_rpc: Dictionary = {
			"content": chat_message["content"],
			"author": chat_message["author"],
			"channel": chat_message["channel"],
			"creation_schedule": chat_message["creation_schedule"]
		}
		receive_chat_message_from_server.rpc(chat_message_for_rpc)
	else:
		print(topic)
		print(message)

func _on_mqtt_broker_connected():
	print("[chat] MQTT chat connected")
	mqtt_client.subscribe("chat/GENERAL")
	mqtt_client.publish("test", "I'm here NOW")

func _on_mqtt_broker_connection_failed():
	print("[chat] MQTT chat failed to connecte :(")

@rpc("any_peer", "call_remote", "unreliable")
func send_chat_message_to_server(message: Dictionary) -> void:

	if not GameOrchestrator.is_server():
		return

	####################
	# TRAITER LE MESSAGE SI BESOIN
	####################

	###################
	# ENVOI VIA MQTT
	var channel_name: String = ""
	if message.has("channel"):
		match message["channel"]:
			0:
				channel_name = "GENERAL"
				mqtt_client.publish("chat/" + channel_name, JSON.stringify({
					"pseudo": message["author"],
					"msg": message["content"],
				}))

	###################
	# ENVOI VIA LE SERVEUR LOCAL
	#receive_chat_message_from_server.rpc(message)
	###################

# Receives a message from the server
@rpc("authority", "call_remote", "unreliable")
func receive_chat_message_from_server(message: Dictionary) -> void:
	if not GameOrchestrator.is_server():
		var chat_message = ChatMessage.new(
			message["content"],
			message["channel"],
			message["author"],
			message["creation_schedule"]
		)
		network_agent.receive_chat_message(chat_message)

#endregion

#########################
# SDO / server meshing  #

func connect_mqtt_sdo():
	if Globals.is_gut_running == true:
		var MqttGut = preload("res://test/servermeshing/sdoInterface.tscn")
		mqtt_client_sdo = MqttGut.instantiate()
	else:
		mqtt_client_sdo = mqtt.instantiate()
	get_tree().get_current_scene().add_child(mqtt_client_sdo)
	#mqtt_client_sdo.client_id = 'gergtrgtrhrrt'
	mqtt_client_sdo.broker_connected.connect(_on_mqtt_sdo_connected)
	mqtt_client_sdo.broker_connection_failed.connect(_on_mqtt_sdo_connection_failed)
	mqtt_client_sdo.received_message.connect(_on_mqtt_sdo_received_message)
	mqtt_client_sdo.verbose_level = server_sdo_verbose_level
	##mqtt_client_sdo.connect_to_broker("tcp://", "192.168.20.158", 1883)
	mqtt_client_sdo.connect_to_broker("ws://", server_sdo_url, server_sdo_port)

func _sdo_register():
	mqtt_client_sdo.subscribe("sdo/serverslist")
	mqtt_client_sdo.subscribe("sdo/players_list")
	mqtt_client_sdo.subscribe("sdo/props_list")
	mqtt_client_sdo.subscribe("sdo/propschanges")
	# register
	var data = JSON.stringify({
		"name": server_name,
		"ip": server_ip,
		"port": server_port,
	})
	mqtt_client_sdo.publish("sdo/register", data)

func _on_mqtt_sdo_connected():
	_sdo_register()

func _on_mqtt_sdo_connection_failed():
	print("Connection to the SDO fail :/")

func _on_mqtt_sdo_received_message(topic, message):
	if topic == "sdo/serverslist":
		# [{
		#	"id": 6,
		#	"name": "gameserver0405",
		#	"ip": "192.168.1.45",
		#	"port": 7050,
		#	"x_start": "",
		#	"x_end": "",
		#	"y_start": "",
		#	"y_end": "",
		#	"z_start": "",
		#	"z_end": "",
		#	"to_split_server_id": null|65
		#	"to_merge_server_id": null|65
		#}]
		var my_servers_list = JSON.parse_string(message)
		for server in my_servers_list:
			if server.name == server_name:
				server_sdo_id = int(server.id)
				is_sdo_active = true
				network_agent.server_zone.x_start = float(server.x_start)
				network_agent.server_zone.x_end = float(server.x_end)
				network_agent.server_zone.y_start = float(server.y_start)
				network_agent.server_zone.y_end = float(server.y_end)
				network_agent.server_zone.z_start = float(server.z_start)
				network_agent.server_zone.z_end = float(server.z_end)

				mqtt_client_sdo.unsubscribe("sdo/serverslist")
				mqtt_client_sdo.subscribe("sdo/serverschanges")

			var split = null
			if server.to_split_server_id != null:
				split = int(server.to_split_server_id)

			servers_list[int(server.id)] = {
				"id": int(server.id),
				"name": server.name,
				"ip": server.ip,
				"port": int(server.port),
				"x_start": server.x_start,
				"x_end": server.x_end,
				"y_start": server.y_start,
				"y_end": server.y_end,
				"z_start": server.z_start,
				"z_end": server.z_end,
				"to_split_server_id": split
			}
		get_gameserver_number_servers.rpc(servers_list.size())
		get_gameserver_serverzone.rpc(network_agent.server_zone)
	elif topic == "sdo/serverschanges":
		var push_players = false
		var servers_received = JSON.parse_string(message)
		# TODO manage when I have updates or if SDO say to me to stop and transfert players
		for server in servers_received.add:
			var split = null
			if server.to_split_server_id != null:
				split = int(server.to_split_server_id)

			servers_list[int(server.id)] = {
				"id": int(server.id),
				"name": server.name,
				"ip": server.ip,
				"port": int(server.port),
				"x_start": server.x_start,
				"x_end": server.x_end,
				"y_start": server.y_start,
				"y_end": server.y_end,
				"z_start": server.z_start,
				"z_end": server.z_end,
				"to_split_server_id": split
			}

			if server.name == server_name:
				server_sdo_id = server.id
				is_sdo_active = true
				network_agent.server_zone.x_start = server.x_start
				network_agent.server_zone.x_end = server.x_end
				network_agent.server_zone.y_start = server.y_start
				network_agent.server_zone.y_end = server.y_end
				network_agent.server_zone.z_start = server.z_start
				network_agent.server_zone.z_end = server.z_end

				mqtt_client_sdo.unsubscribe("sdo/serverslist")
				mqtt_client_sdo.subscribe("sdo/serverschanges")

		for server in servers_received.update:
			if server.id == server_sdo_id:
				if server.to_split_server_id != null:
					push_players = true
					# we pause 2 seconds, time needed for the server load data and players
					await get_tree().create_timer(2).timeout
				if server.to_merge_server_id != null:
					network_agent.set_server_inactive(int(server.to_merge_server_id))

				network_agent.server_zone.x_start = server.x_start
				network_agent.server_zone.x_end = server.x_end
				network_agent.server_zone.y_start = server.y_start
				network_agent.server_zone.y_end = server.y_end
				network_agent.server_zone.z_start = server.z_start
				network_agent.server_zone.z_end = server.z_end
				# if changing_zone == true:
				# 	pass
			# TODO udpate server properties
			else:
				var split = null
				if server.to_split_server_id != null:
					split = int(server.to_split_server_id)
				servers_list[int(server.id)].x_start = server.x_start
				servers_list[int(server.id)].x_end = server.x_end
				servers_list[int(server.id)].y_start = server.y_start
				servers_list[int(server.id)].y_end = server.y_end
				servers_list[int(server.id)].z_start = server.z_start
				servers_list[int(server.id)].z_end = server.z_end
				servers_list[int(server.id)].to_split_server_id = split

		for server in servers_received.delete:
			servers_list.erase(server.id)
		if push_players == true:
			network_agent.transfer_players = true
			network_agent._players_must_change_server()
			# We ending the transfert process
			network_agent.transfer_players = false
			network_agent.changing_zone = false

		get_gameserver_number_servers.rpc(servers_list.size())
		get_gameserver_serverzone.rpc(network_agent.server_zone)

	elif topic == "sdo/players_list":
		print("Playerlists received")
		print(message)
		var players_received = JSON.parse_string(message)
		# ['name', 'client_uuid', 'server_id', 'x', 'y', 'z']
		if is_sdo_active:
			# we have received the first list, we unscribe
			mqtt_client_sdo.unsubscribe("sdo/players_list")
			mqtt_client_sdo.subscribe("sdo/playerschanges")
			for player in players_received:
				if int(player.server_id) != server_sdo_id:
					network_agent.instantiate_player_remote(player, true, int(player.server_id))
		get_gameserver_number_players_universe.rpc(players_list.size() + network_agent.players_list.size())
	elif topic == "sdo/playerschanges":
		# {
		#   "add": [{"name": "playername01", "client_uuid": "", "x": "", "y": "", "z": ""}],
		#   "update": [{"client_uuid": "", "x": "", "y": "", "z": ""}],
		#   "delete": [{"client_uuid": ""}],
		#   "server_id": 5
		# }
		if is_sdo_active == false:
			return
		var players_changes = JSON.parse_string(message)
		if int(players_changes.server_id) != server_sdo_id:
			for player in players_changes.add:
				network_agent.instantiate_player_remote(player, true, int(players_changes.server_id))
			for player in players_changes.update:
				if network_agent.players_list_currently_in_transfert.has(player.client_uuid):
					# despawn the player because on another server now
					network_agent.players_list_temp_by_id.erase(int(network_agent.players_list[player.client_uuid].name))
					network_agent.players_list[player.client_uuid].free()
					network_agent.players_list.erase(player.client_uuid)
					network_agent.players_list_currently_in_transfert.erase(player.client_uuid)
					network_agent.instantiate_player_remote(player, true, int(players_changes.server_id))
				elif players_list.has(player.client_uuid):
					players_list[player.client_uuid].set_global_position(Vector3(player.x, player.y, player.z))
					players_list[player.client_uuid].set_global_rotation(Vector3(player.xr, player.yr, player.zr))
				else:
					network_agent.instantiate_player_remote(player, true)
			for player in players_changes.delete:
				# _players_spawn_node.remove_child(players_list[player.client_uuid])
				players_list[player.client_uuid].free()
				players_list.erase(player.client_uuid)

		update_all_text_client()
	elif topic == "sdo/props_list":
		print("tt")

	elif topic == "sdo/propschanges":
		if is_sdo_active == false:
			return
		var props_changes = JSON.parse_string(message)
		if int(props_changes.server_id) != server_sdo_id:
			for prop in props_changes.add:
				network_agent.instantiate_props_remote_add(prop)
			for prop in props_changes.update:
				network_agent.instantiate_props_remote_update(prop)
	elif topic == "sdo/variableschanges":
		# server variables updates, for all servers
		# {"max_players_allowed": 20}
		var variables = JSON.parse_string(message)
		if variables.has("max_players_allowed"):
			network_agent.max_players_allowed = int(variables.max_players_allowed)
		if variables.has("ServersTickSendPlayersToMQTT"):
			network_agent.servers_ticks_tasks.SendPlayersToMQTTReset = int(variables.ServersTickSendPlayersToMQTT)
		if variables.has("ServersTickSendPropsToMQTT"):
			network_agent.servers_ticks_tasks.SendPropsToMQTTReset = int(variables.ServersTickSendPropsToMQTT)


	else:
		print(topic)
		print(message)


func transfert_player_to_another_server(uuid, server):
	print("expulse to server " + str(server.name))
	network_agent.players_list_currently_in_transfert[uuid] = int(network_agent.players_list[uuid].get_multiplayer_authority())
	rpc_id(int(network_agent.players_list[uuid].get_multiplayer_authority()), "change_server", [server.ip, server.port])

func _create_local_player_not_exists_in_universe(uuid, player_name, spawn_point, id):
	var spawn_position: Vector3 = Vector3.ZERO
	var spawn_up: Vector3 = Vector3.UP
	if spawn_point >= 0 and spawn_point < GameOrchestrator.SPAWN_POINTS_LIST.size():
		var spawn_point_node_path: String = GameOrchestrator.SPAWN_POINTS_LIST[spawn_point]["node_path"]
		#if spawn_point_node_path == "":
			#var parent_entity_spawn_position: Vector3 = universe_scene.get_node("PlanetA").global_position \
			#	if randf() < 0.5 else universe_scene.get_node("PlanetB").global_position
			#spawn_position = random_spawn_on_planet(parent_entity_spawn_position, 2000.0)
			#spawn_up = (spawn_position - parent_entity_spawn_position).normalized()
		if spawn_point_node_path.contains("PlayerSpawnPointsList"):
			spawn_position = universe_scene.get_node(spawn_point_node_path).global_position
			if spawn_point_node_path.contains("PlanetA"):
				spawn_up = (spawn_position - universe_scene.get_node("PlanetA").global_position).normalized()
			elif spawn_point_node_path.contains("PlanetB"):
				spawn_up = (spawn_position - universe_scene.get_node("PlanetB").global_position).normalized()
			elif spawn_point_node_path.contains("StationA"):
				spawn_up = universe_scene.get_node(spawn_point_node_path).transform.basis.y.normalized()
		else:
			push_error("Invalid spawn point node path: ", spawn_point_node_path)
		#else:
			#var parent_entity_spawn_position: Vector3 = universe_scene.get_node(spawn_point_node_path).global_position
			#spawn_position = random_spawn_on_planet(parent_entity_spawn_position, 2000.0)
			#spawn_up = (spawn_position - parent_entity_spawn_position).normalized()

	small_props_spawner_node.spawn({
		"entity": "player",
		"player_scene_path": player_scene_path,
		"player_name": player_name,
		"player_spawn_position": spawn_position,
		"player_spawn_up": Vector3.UP,
		"authority_peer_id": id,
		"uuid": uuid
	})

	var player_to_add
	var sp = universe_scene.get_node("SmallProps")
	var children = sp.get_children()
	for child in children:
		# TODO pas ouf, trouver mieux...
		if child.get_multiplayer_authority() == id:
			player_to_add = child
			break

	network_agent.players_list[uuid] = player_to_add
	network_agent.players_list_temp_by_id[id] = player_to_add;
	print("Nouveau player: ")
	print(player_to_add)


	# network_agent.players_list[uuid].initValues.playername = player_name

	# New player, check if must be in another server (check the zone)
	var new_server = _search_another_server_for_coordinates(
		network_agent.players_list[uuid].global_position[0],
		network_agent.players_list[uuid].global_position[1],
		network_agent.players_list[uuid].global_position[2]
	)
	if new_server != null:
		transfert_player_to_another_server(uuid, new_server)
		return

	network_agent.players_list_temp_by_id[id] = uuid
	var players_data = []
	var position = network_agent.players_list[uuid].get_global_position()
	var rotation = network_agent.players_list[uuid].get_global_rotation()
	var data = ""
	players_data.append({
		"name": player_name,
		"client_uuid": uuid,
		"x": position[0],
		"y": position[1],
		"z": position[2],
		"xr": rotation[0],
		"yr": rotation[1],
		"zr": rotation[2]
	})
	data = JSON.stringify({
		"add": players_data,
		"update": [],
		"delete": [],
		"server_id": server_sdo_id,
	})
	mqtt_client_sdo.publish("sdo/playerschanges", data)
	network_agent.players_list_last_movement[uuid] = Vector3(0.0, 0.0, 0.0)
	network_agent.players_list_last_rotation[uuid] = Vector3(0.0, 0.0, 0.0)

	# Test for remote player
	# var newPlayer = {
	# 	"name": "player test",
	# 	"client_uuid": "32726b4c-119e-4f69-87b1-2495bcabacd9",
	# 	"x": 2146.6928710938,
	# 	"y": 0.0000329,
	# 	"z": 2154.9038085938
	# }

func _create_local_player_come_from_another_server(uuid, player_name, id):
	network_agent.players_list_currently_in_transfert[uuid] = true
	var playerposition = players_list[uuid].global_position
	var playerrotation = players_list[uuid].global_rotation
	print("POSITION1: ", playerposition)
	players_list[uuid].queue_free()
	players_list.erase(uuid)

	# var player_to_add = normal_player.instantiate()
	# player_to_add.name = str(id)
	# player_to_add.initValues.playername = player_name
	# we can now spawn
	# _players_spawn_node.add_child(player_to_add, true)
	var player_to_add = small_props_spawner_node.spawn({
		"entity": "player",
		"player_scene_path": player_scene_path,
		"player_name": player_name,
		"player_spawn_position": playerposition,
		"player_spawn_up": Vector3.UP,
		"authority_peer_id": id
	})
	print("POSITION2: ", playerposition)
	player_to_add.global_position = playerposition
	player_to_add.global_rotation = playerrotation

	if not player_to_add.is_node_ready():
		await player_to_add.ready
	_position_player.rpc_id(id, playerposition, playerrotation)

	network_agent.players_list[uuid] = player_to_add
	network_agent.players_list_temp_by_id[id] = uuid
	network_agent.players_list_last_movement[uuid] = playerposition
	network_agent.players_list_last_rotation[uuid] = playerrotation
	var players_data = []
	var data = ""
	players_data.append({
		"name": player_name,
		"client_uuid": uuid,
		"x": playerposition[0],
		"y": playerposition[1],
		"z": playerposition[2],
		"xr": playerrotation[0],
		"yr": playerrotation[1],
		"zr": playerrotation[2]
	})
	data = JSON.stringify({
		"add": [],
		"update": players_data,
		"delete": [],
		"server_id": server_sdo_id,
	})
	mqtt_client_sdo.publish("sdo/playerschanges", data)
	# TODO, temprory solution, wait 1 second tu prevent change server many times in 1 second and
	# all mechanisms not finished (in another words, player broke it's authority
	# and is blocked on server)
	await get_tree().create_timer(1).timeout

func _search_another_server_for_coordinates(x, y, z):
	for s in servers_list.values():
		if s.id == server_sdo_id:
			continue
		if float(s.x_start) <= x \
			and x < float(s.x_end) \
			and float(s.y_start) <= y \
			and y < float(s.y_end) \
			and float(s.z_start) <= z \
			and z < float(s.z_end):
			return s
	return null

func publish_sdo_newprop(proptype, uuid, position, rotation):
	var data = ""
	var box_data = {
		"type": proptype,
		"uuid": uuid,
		"x": position[0],
		"y": position[1],
		"z": position[2],
		"xr": rotation[0],
		"yr": rotation[1],
		"zr": rotation[2]
	}
	data = JSON.stringify({
		"add": [box_data],
		"update": [],
		"delete": [],
		"server_id": server_sdo_id,
	})
	mqtt_client_sdo.publish("sdo/propschanges", data)

#########################
# Metrics of the server #

func connect_mqtt_metrics():
	mqtt_client_metrics = mqtt.instantiate()
	get_tree().get_current_scene().add_child(mqtt_client_metrics)
	#mqtt_client_metrics.client_id = 'gergtrgtrhrrt'
	mqtt_client_metrics.broker_connected.connect(_on_mqtt_metrics_connected)
	mqtt_client_metrics.broker_connection_failed.connect(_on_mqtt_metrics_connection_failed)
	mqtt_client_metrics.verbose_level = metrics_verbose_level
	##mqtt_client_metrics.connect_to_broker("tcp://", "192.168.20.158", 1883)
	mqtt_client_metrics.connect_to_broker("ws://", metrics_url, metrics_port)

func _on_mqtt_metrics_connected():
	print("metrics connected")

func _on_mqtt_metrics_connection_failed():
	print("Connection to the Metrics fail :/")

func publish_data():
	pass

#########################
# Spawns                #

func get_spawnable_props_newinstance(proptype):
	match proptype:
		"box50cm":
			return small_spawnable_props[2].instantiate()
		"box4m":
			return small_spawnable_props[3].instantiate()
		"ship":
			return load(ship_scene_path).instantiate()
		_:
			return null

@rpc("any_peer", "call_remote", "reliable")
func spawn_prop(proptype,data: Dictionary ) -> void:
	if not GameOrchestrator.is_server():
		return
	var prop_instance: RigidBody3D = get_spawnable_props_newinstance(proptype)
	if prop_instance == null:
		print("ERROR! instance of prop " + proptype + "not found")
	var spawn_position = Vector3(data["x"],data["y"],data["z"])
	var spawn_rotation = Vector3(data["rx"],data["ry"],data["rz"])
	prop_instance.spawn_position = spawn_position
	if data.has("uid"):
		if prop_instance.has_node("DataEntity"):
			prop_instance.get_node("DataEntity").load_obj(data)

	var uuid = UUID_UTIL.v4()
	small_props_spawner_node.get_node(small_props_spawner_node.spawn_path).call_deferred("add_child", prop_instance, true)
	network_agent.props_list[proptype][uuid] = prop_instance
	network_agent.props_list_last_movement[proptype][uuid] = spawn_position
	network_agent.props_list_last_rotation[proptype][uuid] = Vector3.ZERO
	publish_sdo_newprop(proptype, uuid, spawn_position, spawn_rotation)

	# specal case for box50cm
	if proptype == "box50cm" and is_inside_box4m:
		prop_instance.set_collision_layer_value(1, false)
		prop_instance.set_collision_layer_value(2, true)
		prop_instance.set_collision_mask_value(1, false)
		prop_instance.set_collision_mask_value(2, true)

# @rpc("authority", "call_remote", "reliable")
# func spawn_planet(planet_datas: Dictionary) -> void:
# 	# if not multiplayer.is_server():
# 	# 	return

# 	var spawnable_planet_instance: Node3D = spawnable_planet_scene.instantiate()
# 	spawnable_planet_instance.spawn_position = planet_datas["coordinates"]
# 	spawnable_planet_instance.name = planet_datas["name"]

# 	#if spawnable_planet_instance.name == "PlanetB":
# 		#spawnable_planet_instance.material_path = "res://scenes/planet/planet_orange.material"

# 	universe_datas_spawner_node.get_node(universe_datas_spawner_node.spawn_path).call_deferred("add_child", spawnable_planet_instance, true)
# 	network_agent.spawn_data_processed(spawnable_planet_instance)

# @rpc("authority", "call_remote", "reliable")
# func spawn_station(station_datas: Dictionary) -> void:
# 	if not GameOrchestrator.is_server():
# 		return

# 	var spawnable_station_instance: Node3D = spawnable_station_scene.instantiate()
# 	spawnable_station_instance.spawn_position = station_datas["coordinates"]
# 	spawnable_station_instance.name = station_datas["name"]
# 	universe_datas_spawner_node.get_node(universe_datas_spawner_node.spawn_path).call_deferred("add_child", spawnable_station_instance, true)
# 	network_agent.spawn_data_processed(spawnable_station_instance)

@rpc("any_peer", "call_remote", "reliable")
func spawn_player(_player_scene_path: String = "", _spawn_point: int = 0):
	var senderid = universe_scene.multiplayer.get_remote_sender_id()

	if not multiplayer.is_server():
		return

func random_spawn_on_planet(planet_position: Vector3, radius: float) -> Vector3:
	var theta = randf() * TAU					# Angle azimutal
	var phi = acos(1.0 - 2.0 * randf())			# Angle polaire

	var random_point_on_unit_sphere = Vector3(sin(phi) * cos(theta), sin(phi) * sin(theta), cos(phi))

	return planet_position + random_point_on_unit_sphere * (radius + 1.0)

## Request the control of the ship to the server
@rpc("any_peer", "call_remote", "reliable")
func request_control(player_instance_path: String = "", ship_instance_path: String =""):
	if not multiplayer.is_server():
		return

	var senderid = universe_scene.multiplayer.get_remote_sender_id()
	var player_instance = get_node(player_instance_path)
	if player_instance:
		var ship_instance = get_node(ship_instance_path)
		if ship_instance:
			give_control.rpc(senderid, player_instance_path, ship_instance_path)

@rpc("authority", "call_local", "reliable")
func give_control(id, player_instance_path, ship_instance_path):
	var player_instance = get_node(player_instance_path)
	if player_instance:
		var ship_instance = get_node(ship_instance_path)
		if ship_instance:
			ship_instance.pilot = player_instance
			ship_instance.pilot.active = false
			ship_instance.pilot.camera_pivot.rotation.x = 0
			ship_instance.pilot_seat.remote_path = player_instance.get_path()

			ship_instance.set_multiplayer_authority(id)

@rpc("authority", "call_local", "reliable")
func request_release(player_instance_path, ship_instance_path):
	var player_instance = get_node(player_instance_path)
	if player_instance:
		var ship_instance = get_node(ship_instance_path)
		if ship_instance:
			release_control.rpc(player_instance_path, ship_instance_path)

@rpc("any_peer", "call_local", "reliable")
func release_control(player_instance_path, ship_instance_path):
	var player_instance = get_node(player_instance_path)
	if player_instance:
		var ship_instance = get_node(ship_instance_path)
		if ship_instance and ship_instance.pilot != null:
			ship_instance.pilot.active = true
			ship_instance.pilot = null
			ship_instance.pilot_seat.remote_path = NodePath("")
			ship_instance.active = false
			ship_instance.set_multiplayer_authority(1)

@rpc("authority", "call_remote", "reliable")
func notify_client_connected():
	if not multiplayer.is_server():
		network_agent.on_connection_established()

@rpc("any_peer", "call_local", "unreliable")
func set_player_uuid(uuid, player_name, spawn_point: int = 0, id = null):
	if Globals.is_gut_running == false:
		id = universe_scene.multiplayer.get_remote_sender_id()
	network_agent.players_list_currently_in_transfert[uuid] = id
	print("Player with uuid: " + uuid)
	print(players_list.keys())
	if players_list.has(uuid):
		print("UUID FOUND")
		_create_local_player_come_from_another_server(uuid, player_name, id)
	else:
		print("UUID NOT FOUND")
		_create_local_player_not_exists_in_universe(uuid, player_name, spawn_point, id)

	update_all_text_client()
	network_agent.players_list_currently_in_transfert.erase(uuid)


# client receiver RPC functions

@rpc("any_peer", "call_remote", "unreliable", 0)
func change_server(position):
	print("I am expulsed, need to connect to another server")
	_change_server(position)

@rpc("any_peer", "call_remote", "unreliable", 0)
func get_server_name(remoteserver_name):
	set_gameserver_name.emit(remoteserver_name)

@rpc("any_peer", "call_remote", "unreliable", 0)
func get_gameserver_number_players_universe(nb_players):
	set_gameserver_number_players_universe.emit(nb_players)

@rpc("any_peer", "call_remote", "unreliable", 0)
func get_gameserver_number_servers(nb_servers):
	set_gameserver_number_servers.emit(nb_servers)

@rpc("any_peer", "call_remote", "unreliable", 0)
func get_gameserver_number_players(number_players_server):
	set_gameserver_number_players.emit(number_players_server)

@rpc("any_peer", "call_remote", "unreliable", 0)
func get_gameserver_serverzone(serverzone):
	set_gameserver_serverzone.emit(serverzone)

@rpc("any_peer", "call_remote", "unreliable", 0)
func _position_player(pos, rot):
	set_player_global_position.emit(pos, rot)

func _change_server(new_server_info):
	print(new_server_info)
	multiplayer.multiplayer_peer.close()
	client_change_server = new_server_info


func _client_connected_to_server():
	# We are connected
	client_change_server = null
	# set_player_uuid.rpc_id(1, Globals.player_uuid, Globals.player_name)

func _client_disconnected_server():
	# Clean players already loaded
	# var children = small_props_spawner_node.get_children()
	# for child in children:
	# 	child.free()
	if client_change_server != null:
		start_client(universe_scene, client_change_server[0], int(client_change_server[1]), true)
		# var client_peer = ENetMultiplayerPeer.new()
		# client_peer.create_client(client_change_server[0], int(client_change_server[1]))
		# multiplayer.multiplayer_peer = client_peer
	else:
		GameOrchestrator.change_game_state(GameOrchestrator.GameStates.CONNEXION_ERROR)
