extends Node

const uuid_util = preload("res://addons/uuid/uuid.gd")

var SDOServerUrl = ""
var ServerName = ""
var ServerIP = ""
var ServerPort = ""
var isSDOActive = false

var ServerMQTTUrl
var ServerMQTTPort
var ServerMQTTUsername
var ServerMQTTPasword
var ServerMQTTVerboseLevel

var ServerSDOUrl = ""
var ServerSDOPort = 7050
var ServerSDOUsername = ""
var ServerSDOPassword = ""
var ServerSDOVerboseLevel = 2

var MetricsEnabled = false
var MetricsUrl = ""
var MetricsPort = 7050
var MetricsUsername = ""
var MetricsPassword = ""
var MetricsVerboseLevel = 2

const mqtt = preload("res://addons/mqtt/mqtt.tscn")
var MQTTClient
var MQTTClientSDO
var MQTTClientMetrics

var network_agent: Node = null
var universe_scene: Node = null

var small_props_spawner_node: MultiplayerSpawner = null
var small_spawnable_props: Array[PackedScene] = []
var small_spawnable_props_entry_point: Node = null

var universe_datas_spawner_node: MultiplayerSpawner = null
var spawnable_planet_scene: PackedScene = null
var spawnable_station_scene: PackedScene = null

var players: Dictionary[int, Player] = {}
var player_ship: Dictionary[int, Spaceship] = {}

var isInsideBox4m: bool = false

var ServerSDOId = 0
var PlayersList = {}
var ServersList = {}
var PropsList = {
	"box50cm": {},
	"box4m": {},
	"ship": {}
}

var ClientChangeServer = null

var player_scene_path: String = "res://scenes/normal_player/normal_player.tscn"
var ship_scene_path: String = "res://scenes/spaceship/test_spaceship/test_spaceship.tscn"

signal set_gameserver_name(server_name)
signal set_player_global_position(pos, rot)
signal set_gameserver_numberPlayers(number_players_server)
signal set_gameserver_numberServers(nbServers)
signal set_gameserver_numberPlayersUniverse(nbPlayers)
signal set_gameserver_serverzone(serverzone)

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
	
	small_props_spawner_node = universe_scene.get_node("SmallPropsMultiplayerSpawner")
	universe_datas_spawner_node = universe_scene.get_node("UniversDatasMultiplayerSpawner")
	
	var spawnable_planet_path: String = universe_datas_spawner_node.get_spawnable_scene(0)
	spawnable_planet_scene = load(spawnable_planet_path)
	var spawnable_station_path: String = universe_datas_spawner_node.get_spawnable_scene(1)
	spawnable_station_scene = load(spawnable_station_path)
	
	small_props_spawner_node.spawn_function = Callable(self, "_spawn_entity")
	
	preload_small_props(small_props_spawner_node)
	small_spawnable_props_entry_point = small_props_spawner_node.get_node(small_props_spawner_node.get_spawn_path())
	network_agent.start_server(changed_scene, small_spawnable_props_entry_point)
	return network_agent

func start_client(changed_scene, ip = "127.0.0.1", port = 7051, serverChanges: bool = false) -> Node:
	if not serverChanges:
		universe_scene = changed_scene
		small_props_spawner_node = universe_scene.get_node("SmallPropsMultiplayerSpawner")
		
		small_props_spawner_node.spawn_function = Callable(self, "_spawn_entity")
		
		small_props_spawner_node.connect("spawned", _on_entity_spawned)
	
		multiplayer.connected_to_server.connect(_client_connected_to_server)
		multiplayer.server_disconnected.connect(_client_disconnected_server)

		preload_small_props(small_props_spawner_node)
		small_spawnable_props_entry_point = small_props_spawner_node.get_node(small_props_spawner_node.get_spawn_path())
	
	network_agent.start_client(changed_scene, ip, port)
	return network_agent

## Load configuration from server.ini file
func loadServerConfig():
	var config = ConfigFile.new()
	var server_ini = "server.ini"
	for argument in OS.get_cmdline_args():
		if argument.contains("srvini="):
			var key_value = argument.split("=")
			server_ini = key_value[1]
	print("Load server config file: " + server_ini)
	config.load(server_ini)
	ServerIP = config.get_value("server", "ip_public")
	ServerPort = config.get_value("server", "port")
	ServerName = config.get_value("server", "name")
	# Load SDO config
	ServerSDOUrl = config.get_value("server", "sdo_url")
	ServerSDOPort = int(config.get_value("server", "sdo_port"))
	ServerSDOUsername = config.get_value("server", "sdo_username")
	ServerSDOPassword = config.get_value("server", "sdo_password")
	ServerSDOVerboseLevel = config.get_value("server", "sdo_verbose_level")
	# Load chat config
	ServerMQTTUrl = config.get_value("chat", "url")
	ServerMQTTPort = config.get_value("chat", "port")
	ServerMQTTUsername = config.get_value("chat", "username")
	ServerMQTTPasword = config.get_value("chat", "password")
	ServerMQTTVerboseLevel = config.get_value("chat", "verbose_level")
	# Load metric config
	MetricsEnabled = config.get_value("metrics", "enabled")
	MetricsUrl = config.get_value("metrics", "url")
	MetricsPort = config.get_value("metrics", "port")
	MetricsUsername = config.get_value("metrics", "username")
	MetricsPassword = config.get_value("metrics", "password")
	MetricsVerboseLevel = config.get_value("metrics", "verbose_level")


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
	get_gameserver_numberPlayers.rpc(network_agent.PlayersList.size())
	get_server_name.rpc(ServerName)
	get_gameserver_numberServers.rpc(ServersList.size())
	get_gameserver_numberPlayersUniverse.rpc(PlayersList.size() + network_agent.PlayersList.size())
	get_gameserver_serverzone.rpc(network_agent.ServerZone)

###################
# Chat part       #

func connect_chat_mqtt():
	MQTTClient = mqtt.instantiate()
	GameOrchestrator.get_tree().get_current_scene().add_child(MQTTClient)

	MQTTClient.broker_connected.connect(_on_mqtt_broker_connected)
	MQTTClient.broker_connection_failed.connect(_on_mqtt_broker_connection_failed)
	MQTTClient.received_message.connect(_on_mqtt_received_message)
	MQTTClient.verbose_level = ServerMQTTVerboseLevel
	#MQTTClient.connect_to_broker("tcp://", "192.168.20.158", 1883)
	MQTTClient.connect_to_broker("ws://", ServerMQTTUrl, ServerMQTTPort)

func _on_mqtt_received_message(topic, message):
	if topic == "chat/GENERAL":
		var chatData = JSON.parse_string(message)
		var chat_message = ChatMessage.new(chatData.msg, 0, chatData.pseudo, 0.0)
		var chat_message_for_rpc: Dictionary = {"content": chat_message["content"], "author": chat_message["author"], "channel": chat_message["channel"], "creation_schedule": chat_message["creation_schedule"]}
		receive_chat_message_from_server.rpc(chat_message_for_rpc)
	else:
		print(topic)
		print(message)

func _on_mqtt_broker_connected():
	print("[chat] MQTT chat connected")
	MQTTClient.subscribe("chat/GENERAL")
	MQTTClient.publish("test", "I'm here NOW")

func _on_mqtt_broker_connection_failed():
	print("[chat] MQTT chat failed to connecte :(")

@rpc("any_peer", "call_remote", "unreliable")
func send_chat_message_to_server(message: Dictionary) -> void:

	if not multiplayer.is_server():
		return
	
	####################
	# TRAITER LE MESSAGE SI BESOIN
	####################
		
	###################
	# ENVOI VIA MQTT
	var channelName: String = ""
	if message.has("channel"):
		match message["channel"]:
			0:
				channelName = "GENERAL"
				MQTTClient.publish("chat/" + channelName, JSON.stringify({
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
	if not multiplayer.is_server():
		var chat_message = ChatMessage.new(message["content"], message["channel"], message["author"], message["creation_schedule"])
		network_agent.receive_chat_message(chat_message)

#endregion

#########################
# SDO / server meshing  #

func connect_mqtt_sdo():
	if Globals.isGUTRunning == true:
		var mqttGUT = preload("res://test/servermeshing/sdoInterface.tscn")
		MQTTClientSDO = mqttGUT.instantiate()
	else:
		MQTTClientSDO = mqtt.instantiate()
	get_tree().get_current_scene().add_child(MQTTClientSDO)
	#MQTTClientSDO.client_id = 'gergtrgtrhrrt'
	MQTTClientSDO.broker_connected.connect(_on_mqtt_sdo_connected)
	MQTTClientSDO.broker_connection_failed.connect(_on_mqtt_sdo_connection_failed)
	MQTTClientSDO.received_message.connect(_on_mqtt_sdo_received_message)
	MQTTClientSDO.verbose_level = ServerSDOVerboseLevel
	##MQTTClientSDO.connect_to_broker("tcp://", "192.168.20.158", 1883)
	MQTTClientSDO.connect_to_broker("ws://", ServerSDOUrl, ServerSDOPort)

func _sdo_register():
	MQTTClientSDO.subscribe("sdo/serverslist")
	MQTTClientSDO.subscribe("sdo/playerslist")
	MQTTClientSDO.subscribe("sdo/propslist")
	MQTTClientSDO.subscribe("sdo/propschanges")
	# register
	var data = JSON.stringify({
		"name": ServerName,
		"ip": ServerIP,
		"port": ServerPort,
	})
	MQTTClientSDO.publish("sdo/register", data)

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
		var serversList = JSON.parse_string(message)
		for server in serversList:
			if server.name == ServerName:
				ServerSDOId = int(server.id)
				isSDOActive = true
				network_agent.ServerZone.x_start = float(server.x_start)
				network_agent.ServerZone.x_end = float(server.x_end)
				network_agent.ServerZone.y_start = float(server.y_start)
				network_agent.ServerZone.y_end = float(server.y_end)
				network_agent.ServerZone.z_start = float(server.z_start)
				network_agent.ServerZone.z_end = float(server.z_end)

				MQTTClientSDO.unsubscribe("sdo/serverslist")
				MQTTClientSDO.subscribe("sdo/serverschanges")

			var split = null
			if server.to_split_server_id != null:
				split = int(server.to_split_server_id)

			ServersList[int(server.id)] = {
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
		get_gameserver_numberServers.rpc(ServersList.size())
		get_gameserver_serverzone.rpc(network_agent.ServerZone)
	elif topic == "sdo/serverschanges":
		var pushPlayers = false
		var serversReceived = JSON.parse_string(message)
		# TODO manage when I have updates or if SDO say to me to stop and transfert players
		for server in serversReceived.add:
			var split = null
			if server.to_split_server_id != null:
				split = int(server.to_split_server_id)

			ServersList[int(server.id)] = {
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

			if server.name == ServerName:
				ServerSDOId = server.id
				isSDOActive = true
				network_agent.ServerZone.x_start = server.x_start
				network_agent.ServerZone.x_end = server.x_end
				network_agent.ServerZone.y_start = server.y_start
				network_agent.ServerZone.y_end = server.y_end
				network_agent.ServerZone.z_start = server.z_start
				network_agent.ServerZone.z_end = server.z_end

				MQTTClientSDO.unsubscribe("sdo/serverslist")
				MQTTClientSDO.subscribe("sdo/serverschanges")
			
		for server in serversReceived.update:
			if server.id == ServerSDOId:
				if server.to_split_server_id != null:
					pushPlayers = true
					# we pause 2 seconds, time needed for the server load data and players
					await get_tree().create_timer(2).timeout
				if server.to_merge_server_id != null:
					network_agent.set_server_inactive(int(server.to_merge_server_id))

				network_agent.ServerZone.x_start = server.x_start
				network_agent.ServerZone.x_end = server.x_end
				network_agent.ServerZone.y_start = server.y_start
				network_agent.ServerZone.y_end = server.y_end
				network_agent.ServerZone.z_start = server.z_start
				network_agent.ServerZone.z_end = server.z_end
				# if ChangingZone == true:
				# 	pass
			# TODO udpate server properties
			else:
				var split = null
				if server.to_split_server_id != null:
					split = int(server.to_split_server_id)
				ServersList[int(server.id)].x_start = server.x_start
				ServersList[int(server.id)].x_end = server.x_end
				ServersList[int(server.id)].y_start = server.y_start
				ServersList[int(server.id)].y_end = server.y_end
				ServersList[int(server.id)].z_start = server.z_start
				ServersList[int(server.id)].z_end = server.z_end
				ServersList[int(server.id)].to_split_server_id = split

		for server in serversReceived.delete:
			ServersList.erase(server.id)
		if pushPlayers == true:
			network_agent.TransferPlayers = true
			network_agent._playersMustChangeServer()
			# We ending the transfert process
			network_agent.TransferPlayers = false
			network_agent.ChangingZone = false

		get_gameserver_numberServers.rpc(ServersList.size())
		get_gameserver_serverzone.rpc(network_agent.ServerZone)

	elif topic == "sdo/playerslist":
		print("Playerlists received")
		print(message)
		var playersReceived = JSON.parse_string(message)
		# ['name', 'client_uuid', 'server_id', 'x', 'y', 'z']
		if isSDOActive:
			# we have received the first list, we unscribe
			MQTTClientSDO.unsubscribe("sdo/playerslist")
			MQTTClientSDO.subscribe("sdo/playerschanges")
			for player in playersReceived:
				if int(player.server_id) != ServerSDOId:
					network_agent.instantiate_player_remote(player, true, int(player.server_id))
		get_gameserver_numberPlayersUniverse.rpc(PlayersList.size() + network_agent.PlayersList.size())
	elif topic == "sdo/playerschanges":
		# {
		#   "add": [{"name": "playername01", "client_uuid": "", "x": "", "y": "", "z": ""}],
		#   "update": [{"client_uuid": "", "x": "", "y": "", "z": ""}],
		#   "delete": [{"client_uuid": ""}],
		#   "server_id": 5
		# }
		if isSDOActive == false:
			return
		var playersChanges = JSON.parse_string(message)
		if int(playersChanges.server_id) != ServerSDOId:
			for player in playersChanges.add:
				network_agent.instantiate_player_remote(player, true, int(playersChanges.server_id))
			for player in playersChanges.update:
				if network_agent.PlayersListCurrentlyInTransfert.has(player.client_uuid):
					# despawn the player because on another server now
					network_agent.PlayersListTempById.erase(int(network_agent.PlayersList[player.client_uuid].name))
					network_agent.PlayersList[player.client_uuid].free()
					network_agent.PlayersList.erase(player.client_uuid)
					network_agent.PlayersListCurrentlyInTransfert.erase(player.client_uuid)
					network_agent.instantiate_player_remote(player, true, int(playersChanges.server_id))
				elif PlayersList.has(player.client_uuid):
					PlayersList[player.client_uuid].set_global_position(Vector3(player.x, player.y, player.z))
					PlayersList[player.client_uuid].set_global_rotation(Vector3(player.xr, player.yr, player.zr))
				else:
					network_agent.instantiate_player_remote(player, true)
			for player in playersChanges.delete:
				# _players_spawn_node.remove_child(PlayersList[player.client_uuid])
				PlayersList[player.client_uuid].free()
				PlayersList.erase(player.client_uuid)

		update_all_text_client()
	elif topic == "sdo/propslist":
		print("tt")

	elif topic == "sdo/propschanges":
		if isSDOActive == false:
			return
		var propsChanges = JSON.parse_string(message)
		if int(propsChanges.server_id) != ServerSDOId:
			for prop in propsChanges.add:
				network_agent.instantiate_props_remote_add(prop)
			for prop in propsChanges.update:
				network_agent.instantiate_props_remote_update(prop)
	elif topic == "sdo/variableschanges":
		# server variables updates, for all servers
		# {"MaxPlayersAllowed": 20}
		var variables = JSON.parse_string(message)
		if variables.has("MaxPlayersAllowed"):
			network_agent.MaxPlayersAllowed = int(variables.MaxPlayersAllowed)
		if variables.has("ServersTickSendPlayersToMQTT"):
			network_agent.ServersTicksTasks.SendPlayersToMQTTReset = int(variables.ServersTickSendPlayersToMQTT)
		if variables.has("ServersTickSendPropsToMQTT"):
			network_agent.ServersTicksTasks.SendPropsToMQTTReset = int(variables.ServersTickSendPropsToMQTT)
		

	else:
		print(topic)
		print(message)


func transfert_player_to_another_server(uuid, server):
	print("expulse to server " + str(server.name))
	network_agent.PlayersListCurrentlyInTransfert[uuid] = int(network_agent.PlayersList[uuid].get_multiplayer_authority())
	rpc_id(int(network_agent.PlayersList[uuid].get_multiplayer_authority()), "change_server", [server.ip, server.port])

func _create_local_player_not_exists_in_universe(uuid, playerName, spawn_point, id):
	var spawn_position: Vector3 = Vector3.ZERO
	var spawn_up: Vector3 = Vector3.UP
	if spawn_point >= 0 and spawn_point < GameOrchestrator.SPAWN_POINTS_LIST.size():
		var spawn_point_node_path: String = GameOrchestrator.SPAWN_POINTS_LIST[spawn_point]["node_path"]
		#if spawn_point_node_path == "":
			#var parent_entity_spawn_position: Vector3 = universe_scene.get_node("PlanetA").global_position if randf() < 0.5 else universe_scene.get_node("PlanetB").global_position
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
		"player_name": playerName,
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

	network_agent.PlayersList[uuid] = player_to_add
	network_agent.PlayersListTempById[id] = player_to_add;
	print("Nouveau player: ")
	print(player_to_add)


	# network_agent.PlayersList[uuid].initValues.playername = playerName

	# New player, check if must be in another server (check the zone)
	var newServer = _searchAnotherServerForCoordinates(
		network_agent.PlayersList[uuid].global_position[0],
		network_agent.PlayersList[uuid].global_position[1],
		network_agent.PlayersList[uuid].global_position[2]
	)
	if newServer != null:
		transfert_player_to_another_server(uuid, newServer)
		return

	network_agent.PlayersListTempById[id] = uuid
	var playersData = []
	var position = network_agent.PlayersList[uuid].get_global_position()
	var rotation = network_agent.PlayersList[uuid].get_global_rotation()
	var data = ""
	playersData.append({
		"name": playerName,
		"client_uuid": uuid,
		"x": position[0],
		"y": position[1],
		"z": position[2],
		"xr": rotation[0],
		"yr": rotation[1],
		"zr": rotation[2]
	})
	data = JSON.stringify({
		"add": playersData,
		"update": [],
		"delete": [],
		"server_id": ServerSDOId,
	})
	MQTTClientSDO.publish("sdo/playerschanges", data)
	network_agent.PlayersListLastMovement[uuid] = Vector3(0.0, 0.0, 0.0)
	network_agent.PlayersListLastRotation[uuid] = Vector3(0.0, 0.0, 0.0)

	# Test for remote player
	# var newPlayer = {
	# 	"name": "player test",
	# 	"client_uuid": "32726b4c-119e-4f69-87b1-2495bcabacd9",
	# 	"x": 2146.6928710938,
	# 	"y": 0.0000329,
	# 	"z": 2154.9038085938
	# }

func _create_local_player_come_from_another_server(uuid, playerName, id):
	network_agent.PlayersListCurrentlyInTransfert[uuid] = true
	var playerposition = PlayersList[uuid].global_position
	var playerrotation = PlayersList[uuid].global_rotation
	print("POSITION1: ", playerposition)
	PlayersList[uuid].queue_free()
	PlayersList.erase(uuid)

	# var player_to_add = normal_player.instantiate()
	# player_to_add.name = str(id)
	# player_to_add.initValues.playername = playerName
	# we can now spawn
	# _players_spawn_node.add_child(player_to_add, true)
	var player_to_add = small_props_spawner_node.spawn({
		"entity": "player",
		"player_scene_path": player_scene_path,
		"player_name": playerName,
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

	network_agent.PlayersList[uuid] = player_to_add
	network_agent.PlayersListTempById[id] = uuid
	network_agent.PlayersListLastMovement[uuid] = playerposition
	network_agent.PlayersListLastRotation[uuid] = playerrotation
	var playersData = []
	var data = ""
	playersData.append({
		"name": playerName,
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
		"update": playersData,
		"delete": [],
		"server_id": ServerSDOId,
	})
	MQTTClientSDO.publish("sdo/playerschanges", data)
	# TODO, temprory solution, wait 1 second tu prevent change server many times in 1 second and 
	# all mechanisms not finished (in another words, player broke it's authority
	# and is blocked on server)
	await get_tree().create_timer(1).timeout

func _searchAnotherServerForCoordinates(x, y, z):
	for s in ServersList.values():
		if s.id == ServerSDOId:
			continue
		if float(s.x_start) <= x and x < float(s.x_end) and float(s.y_start) <= y and y < float(s.y_end) and float(s.z_start) <= z and z < float(s.z_end):
			return s
	return null

func publish_sdo_newprop(proptype, uuid, position, rotation):
	var data = ""
	var boxData = {
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
		"add": [boxData],
		"update": [],
		"delete": [],
		"server_id": ServerSDOId,
	})
	MQTTClientSDO.publish("sdo/propschanges", data)

#########################
# Metrics of the server #

func connect_mqtt_metrics():
	MQTTClientMetrics = mqtt.instantiate()
	get_tree().get_current_scene().add_child(MQTTClientMetrics)
	#MQTTClientMetrics.client_id = 'gergtrgtrhrrt'
	MQTTClientMetrics.broker_connected.connect(_on_mqtt_metrics_connected)
	MQTTClientMetrics.broker_connection_failed.connect(_on_mqtt_metrics_connection_failed)
	MQTTClientMetrics.verbose_level = MetricsVerboseLevel
	##MQTTClientMetrics.connect_to_broker("tcp://", "192.168.20.158", 1883)
	MQTTClientMetrics.connect_to_broker("ws://", MetricsUrl, MetricsPort)

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
func spawn_prop(proptype,data: Dictionary ) -> void: #spawn_position: Vector3 = Vector3.ZERO, spawn_rotation: Vector3 = Vector3.UP) -> void:
	if not multiplayer.is_server():
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
		
	var uuid = uuid_util.v4()
	small_props_spawner_node.get_node(small_props_spawner_node.spawn_path).call_deferred("add_child", prop_instance, true)
	network_agent.PropsList[proptype][uuid] = prop_instance
	network_agent.PropsListLastMovement[proptype][uuid] = spawn_position
	network_agent.PropsListLastRotation[proptype][uuid] = Vector3.ZERO
	publish_sdo_newprop(proptype, uuid, spawn_position, spawn_rotation)

	# specal case for box50cm
	if proptype == "box50cm" and isInsideBox4m:
		prop_instance.set_collision_layer_value(1, false)
		prop_instance.set_collision_layer_value(2, true)
		prop_instance.set_collision_mask_value(1, false)
		prop_instance.set_collision_mask_value(2, true)

@rpc("authority", "call_remote", "reliable")
func spawn_planet(planet_datas: Dictionary) -> void:
	# if not multiplayer.is_server():
	# 	return
	
	var spawnable_planet_instance: Node3D = spawnable_planet_scene.instantiate()
	spawnable_planet_instance.spawn_position = planet_datas["coordinates"]
	spawnable_planet_instance.name = planet_datas["name"]
	
	#if spawnable_planet_instance.name == "PlanetB":
		#spawnable_planet_instance.material_path = "res://scenes/planet/planet_orange.material"
		
	universe_datas_spawner_node.get_node(universe_datas_spawner_node.spawn_path).call_deferred("add_child", spawnable_planet_instance, true)
	network_agent.spawn_data_processed(spawnable_planet_instance)

@rpc("authority", "call_remote", "reliable")
func spawn_station(station_datas: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	
	var spawnable_station_instance: Node3D = spawnable_station_scene.instantiate()
	spawnable_station_instance.spawn_position = station_datas["coordinates"]
	spawnable_station_instance.name = station_datas["name"]
	universe_datas_spawner_node.get_node(universe_datas_spawner_node.spawn_path).call_deferred("add_child", spawnable_station_instance, true)
	network_agent.spawn_data_processed(spawnable_station_instance)

@rpc("any_peer", "call_remote", "reliable")
func spawn_player(player_scene_path: String = "", spawn_point: int = 0):
	var senderid = universe_scene.multiplayer.get_remote_sender_id()
	
	if not multiplayer.is_server():
		return
	
	# small_props_spawner_node.spawn({"entity": "player", "player_scene_path": player_scene_path, "player_name": "Player_" + str(senderid), "player_spawn_position": spawn_position, "player_spawn_up": spawn_up, "authority_peer_id": senderid})

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
func set_player_uuid(uuid, playerName, spawn_point: int = 0, id = null):
	if Globals.isGUTRunning == false:
		id = universe_scene.multiplayer.get_remote_sender_id()
	network_agent.PlayersListCurrentlyInTransfert[uuid] = id
	print("Player with uuid: " + uuid)
	print(PlayersList.keys())
	if PlayersList.has(uuid):
		print("UUID FOUND")
		_create_local_player_come_from_another_server(uuid, playerName, id)
	else:
		print("UUID NOT FOUND")
		_create_local_player_not_exists_in_universe(uuid, playerName, spawn_point, id)

	update_all_text_client()
	network_agent.PlayersListCurrentlyInTransfert.erase(uuid)


# client receiver RPC functions

@rpc("any_peer", "call_remote", "unreliable", 0)
func change_server(position):
	print("I am expulsed, need to connect to another server")
	_changeServer(position)

@rpc("any_peer", "call_remote", "unreliable", 0)
func get_server_name(remoteServerName):
	set_gameserver_name.emit(remoteServerName)

@rpc("any_peer", "call_remote", "unreliable", 0)
func get_gameserver_numberPlayersUniverse(nbPlayers):
	set_gameserver_numberPlayersUniverse.emit(nbPlayers)

@rpc("any_peer", "call_remote", "unreliable", 0)
func get_gameserver_numberServers(nbServers):
	set_gameserver_numberServers.emit(nbServers)

@rpc("any_peer", "call_remote", "unreliable", 0)
func get_gameserver_numberPlayers(number_players_server):
	set_gameserver_numberPlayers.emit(number_players_server)

@rpc("any_peer", "call_remote", "unreliable", 0)
func get_gameserver_serverzone(serverzone):
	set_gameserver_serverzone.emit(serverzone)

@rpc("any_peer", "call_remote", "unreliable", 0)
func _position_player(pos, rot):
	set_player_global_position.emit(pos, rot)

func _changeServer(newServerInfo):
	print(newServerInfo)
	multiplayer.multiplayer_peer.close()
	ClientChangeServer = newServerInfo


func _client_connected_to_server():
	# We are connected
	ClientChangeServer = null
	# set_player_uuid.rpc_id(1, Globals.playerUUID, Globals.playerName)

func _client_disconnected_server():
	# Clean players already loaded
	# var children = small_props_spawner_node.get_children()
	# for child in children:
	# 	child.free()
	if ClientChangeServer != null:
		start_client(universe_scene, ClientChangeServer[0], int(ClientChangeServer[1]), true)
		# var client_peer = ENetMultiplayerPeer.new()
		# client_peer.create_client(ClientChangeServer[0], int(ClientChangeServer[1]))
		# multiplayer.multiplayer_peer = client_peer
	else:
		GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.CONNEXION_ERROR)
