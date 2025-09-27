extends Node

signal populated_universe

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

# Horizon port we will listen to.
const PORT = 8980


var universe_scene: Node = null
var entities_spawn_node: Node = null
var datas_to_spawn_count: int = 0

var clients_peers_ids: Array[int] = []

var server_zone = {
	"x_start": -100000.0,
	"x_end": 100000.0,
	"y_start": -100000.0,
	"y_end": 100000.0,
	"z_start": -100000.0,
	"z_end": 100000.0
}

var max_players_allowed = 40
var players_list = {}
var players_list_last_movement = {}
var players_list_last_rotation = {}
var players_list_temp_by_id = {}
var players_list_currently_in_transfert = {}
var changing_zone = false
var transfer_players = false
var props_list = {
	"planets": {},
	"box50cm": {},
	"box4m": {},
	"ship": {},
}
var props_list_last_movement = {
	# "box50cm": {},
	# "box4m": {},
	# "ship": {},
}
var props_list_last_rotation = {
	# "box50cm": {},
	# "box4m": {},
	# "ship": {},
}

var servers_ticks_tasks = {
	"TooManyPlayersCurent": 3600,
	"TooManyPlayersReset": 3600, # all 1 minute
	"SendPlayersToMQTTCurrent": 15,
	"SendPlayersToMQTTReset": 15,
	"CheckPlayersOutOfZoneCurrent": 20,
	"CheckPlayersOutOfZoneReset": 20,
	"SendPropsToMQTTCurrent": 15,
	"SendPropsToMQTTReset": 15,
	"SendMetricsCurrent": 120,
	"SendMetricsReset": 120,
}

var players_newposition: Dictionary = {}
var props_newposition: Dictionary = {}

# Horizon server
# Our TCP Server instance.
var tcp_server = TCPServer.new()
# Our connected peers list.
var peer := WebSocketPeer.new()

var planet_scene = preload("res://scenes/planet/testplanet.tscn")
var player_scene_path: String = "res://scenes/normal_player/normal_player.tscn"

var player_scene: PackedScene = preload("res://scenes/normal_player/normal_player.tscn")
var box50cm_scene: PackedScene = preload("res://scenes/props/testbox/box_50cm.tscn")

var debug_message_number: int = 0

func _enter_tree() -> void:
	NetworkOrchestrator.load_server_config()

func _ready() -> void:
	set_process(false)

func _physics_process(_delta: float) -> void:
	send_players_newposition_to_horizon()
	send_props_newposition_to_horizon()
	if NetworkOrchestrator.is_sdo_active == true:
		_is_server_has_too_many_players()
		_send_players_to_sdo()
		_check_player_out_of_zone()
		_send_props_to_sdo()
	# for uuid in players_list.keys():
	# 	if players_list_last_movement[uuid] != players_list[uuid].global_position:
	# 		players_list_last_movement[uuid] = players_list[uuid].global_position


func start_server(receveid_universe_scene: Node) -> void:
	Engine.physics_ticks_per_second = 30
	Engine.max_fps = 30

	universe_scene = receveid_universe_scene
	# entities_spawn_node = receveid_player_spawn_node
	# var server_peer = ENetMultiplayerPeer.new()
	# if not server_peer:
	# 	printerr("creating server_peer failed!")
	# 	return

	# var res = server_peer.create_server(NetworkOrchestrator.server_port, 150)
	# if res != OK:
	# 	printerr("creating server failed: ", error_string(res))
	# 	return

	# universe_scene.multiplayer.multiplayer_peer = server_peer
	# NetworkOrchestrator.connect_chat_mqtt()
	# # load SDO mqtt in NetworkOrchestrator
	# NetworkOrchestrator.connect_mqtt_sdo()
	# if NetworkOrchestrator.metrics_enabled == true:
	# 	NetworkOrchestrator.connect_mqtt_metrics()
	print("server loaded... \\o/")
	# universe_scene.multiplayer.peer_connected.connect(_on_client_peer_connected)
	# universe_scene.multiplayer.peer_disconnected.connect(_on_client_peer_disconnect)

	start_websocket_server()

func start_websocket_server():
	var err = tcp_server.listen(PORT)
	if err == OK:
		print("Server socket started.")
		set_process(true)
	else:
		push_error("Unable to start server socket.")

func _process(_delta: float) -> void:
	while tcp_server.is_connection_available():
		print("Peer connected (Horizon server).")
		peer.accept_stream(tcp_server.take_connection())

	peer.poll()

	var peer_state = peer.get_ready_state()
	if peer_state == WebSocketPeer.STATE_OPEN:
		while peer.get_available_packet_count():
			var packet = peer.get_packet()
			if peer.was_string_packet():
				var packet_text = packet.get_string_from_utf8()
				# print("Received packet: %s" % [packet_text])
				var message = JSON.parse_string(packet_text)
				if message != null:
					dispatch_horizon_message(message)

				# Echo the packet back.
				# peer.send_text(packet_text)
			else:
				print("< Got binary data from peer: %d ... echoing" % [packet.size()])
				# Echo the packet back.
				peer.send(packet)
	# elif peer_state == WebSocketPeer.STATE_CLOSED:
	# 	# Remove the disconnected peer.
	# 	var code = peer.get_close_code()
	# 	var reason = peer.get_close_reason()
	# 	print("- Peer closed with code: %d, reason %s. Clean: %s" % [code, reason, code != -1])

func populate_universe(datas: Dictionary) -> void:

	if datas.has("datas_count"):
		datas_to_spawn_count = datas["datas_count"]

	for data_key in datas:
		match data_key:
			"planets":
				for planet in range(datas[data_key].size()):
					NetworkOrchestrator.spawn_planet(datas[data_key][planet])
			"stations":
				for station in range(datas[data_key].size()):
					NetworkOrchestrator.spawn_station(datas[data_key][station])

func spawn_data_processed(spawned_entity: Node) -> void:
	await spawned_entity.ready
	datas_to_spawn_count -= 1
	if datas_to_spawn_count == 0:
		emit_signal("populated_universe", universe_scene)

func _on_client_peer_connected(peer_id: int):
	clients_peers_ids.append(peer_id)
	NetworkOrchestrator.notify_client_connected.rpc_id(peer_id)

func _on_client_peer_disconnect(id):
	print("player " + str(id) + " disconnected")
	var player = entities_spawn_node.get_node_or_null("Player_" + str(id))
	if player:
		player.queue_free()

	if NetworkOrchestrator.player_ship.has(id):
		var ship = NetworkOrchestrator.player_ship[id]
		if ship:
			ship.queue_free()

	NetworkOrchestrator.players.erase(id)
	NetworkOrchestrator.player_ship.erase(id)

	# TODO manage players move to another server and players disconnect completly
	var uuid = players_list_temp_by_id[id]
	if not players_list_currently_in_transfert.has(uuid):
		var data = JSON.stringify({
			"add": [],
			"update": [],
			"delete": [{"client_uuid" : players_list_temp_by_id[id]}],
			"server_id": NetworkOrchestrator.server_sdo_id,
		})
		NetworkOrchestrator.mqtt_client_sdo.publish("sdo/playerschanges", data)
		players_list_temp_by_id.erase(multiplayer.get_remote_sender_id())
		players_list.erase(players_list_temp_by_id[id])

		# player.queue_free()
	NetworkOrchestrator.update_all_text_client()



func _is_server_has_too_many_players():
	if servers_ticks_tasks.TooManyPlayersCurent > 0:
		servers_ticks_tasks.TooManyPlayersCurent -= 1
	else:
		if players_list.size() > max_players_allowed and changing_zone == false:
			if _players_must_change_server() == false:
				var players_data = []
				for value in players_list.values():
					var position = value.global_position
					if position != Vector3.ZERO:
						# can have position zero if spawn not yet defined and it can break split of servers
						players_data.append({"x": position[0], "y": position[1], "z": position[2]})
				print("######################################################")
				print("####################### Too many players, need split #")
				changing_zone = true
				NetworkOrchestrator.mqtt_client_sdo.publish("sdo/servertooheavy", JSON.stringify({
					"id": NetworkOrchestrator.server_sdo_id,
					"players": players_data,
				}))
		servers_ticks_tasks.TooManyPlayersCurent = servers_ticks_tasks.TooManyPlayersReset

func _send_players_to_sdo():
	if servers_ticks_tasks.SendPlayersToMQTTCurrent > 0:
		servers_ticks_tasks.SendPlayersToMQTTCurrent -= 1
	else:
		var players_data = []
		var position = Vector3(0.0, 0.0, 0.0)
		var rotation = Vector3(0.0, 0.0, 0.0)
		for puuid in players_list.keys():
			position = players_list[puuid].global_position
			rotation = players_list[puuid].global_rotation
			if players_list_last_movement[puuid] != position or players_list_last_rotation[puuid] != rotation:
				if not players_list_currently_in_transfert.has(puuid):
					# only the players of this server and not in transfert
					players_data.append({
						"name": players_list[puuid].name,
						"client_uuid": puuid,
						"x": position[0],
						"y": position[1],
						"z": position[2],
						"xr": rotation[0],
						"yr": rotation[1],
						"zr": rotation[2]
					})
					players_list_last_movement[puuid] = position
					players_list_last_rotation[puuid] = rotation
		if players_data.size() > 0:
			NetworkOrchestrator.mqtt_client_sdo.publish("sdo/playerschanges", JSON.stringify({
				"add": [],
				"update": players_data,
				"delete": [],
				"server_id": NetworkOrchestrator.server_sdo_id,
			}))
		servers_ticks_tasks.SendPlayersToMQTTCurrent = servers_ticks_tasks.SendPlayersToMQTTReset

func _check_player_out_of_zone():
	if servers_ticks_tasks.CheckPlayersOutOfZoneCurrent > 0:
		servers_ticks_tasks.CheckPlayersOutOfZoneCurrent -= 1
	else:
		if changing_zone == false:
			_players_must_change_server()
		servers_ticks_tasks.CheckPlayersOutOfZoneCurrent = servers_ticks_tasks.CheckPlayersOutOfZoneReset

func _players_must_change_server():
	# loop on coordinates of new server
	var some_players_transfered = false
	for puuid in players_list.keys():
		if players_list_currently_in_transfert.has(puuid):
			continue
		var position = players_list[puuid].global_position
		if position[0] < server_zone.x_start or position[0] > server_zone.x_end:
			print("Expulse player X: " + str(puuid))
			print("serverstart, server end, player: ", server_zone.x_start, " ", server_zone.x_end, " ", position[0])
			var new_server = _search_another_server_for_coordinates(position[0], position[1], position[2])
			if new_server != null:
				NetworkOrchestrator.transfert_player_to_another_server(puuid, new_server)
				some_players_transfered = true
			else:
				print("ERROR: no server found to expulse :/")
		elif position[1] < server_zone.y_start or position[1] > server_zone.y_end:
			print("Expulse player Y: " + str(puuid))
			print("serverstart, server end, player: ", server_zone.y_start, " ", server_zone.y_end, " ", position[1])
			var new_server = _search_another_server_for_coordinates(position[0], position[1], position[2])
			if new_server != null:
				NetworkOrchestrator.transfert_player_to_another_server(puuid, new_server)
				some_players_transfered = true
		elif position[2] < server_zone.z_start or position[2] > server_zone.z_end:
			print("Expulse player Z: " + str(puuid))
			print("serverstart, server end, player: ", server_zone.z_start, " ", server_zone.z_end, " ", position[2])
			var new_server = _search_another_server_for_coordinates(position[0], position[1], position[2])
			if new_server != null:
				NetworkOrchestrator.transfert_player_to_another_server(puuid, new_server)
				some_players_transfered = true
	return some_players_transfered

func _search_another_server_for_coordinates(x, y, z):
	for s in NetworkOrchestrator.servers_list.values():
		if s.id == NetworkOrchestrator.server_sdo_id:
			continue
		if float(s.x_start) <= x \
			and x < float(s.x_end) \
			and float(s.y_start) <= y \
			and y < float(s.y_end) \
			and float(s.z_start) <= z \
			and z < float(s.z_end):
			return s
	return null

# Instantiate remote server player, need to be visible for players on this server
func instantiate_player_remote(player, set_player_position = false, server_id = null):
	var playername = "Pigeon with no name"
	if player.has("name"):
		playername = player.name
	var spawn_position: Vector3 = Vector3.ZERO
	if set_player_position == true:
		spawn_position = Vector3(float(player.x), float(player.y), float(player.z))
		print("Remnote player spawn with position: ", spawn_position)

	var player_to_add = NetworkOrchestrator.small_props_spawner_node.spawn({
		"entity": "player",
		"player_scene_path": NetworkOrchestrator.player_scene_path,
		"player_name": "remoteplayer" + playername,
		"player_spawn_position": spawn_position,
		"player_spawn_up": Vector3.UP,
		"authority_peer_id": 1
	})
	player_to_add.name = playername
	player_to_add.label_player_name.text = playername
	player_to_add.global_rotation = Vector3(float(player.xr), float(player.yr), float(player.zr))
	player_to_add.set_physics_process(false)
	NetworkOrchestrator.players_list[player.client_uuid] = player_to_add
	if server_id != null:
		player_to_add.label_server_name.text = NetworkOrchestrator.servers_list[server_id].name

	print("Remnote player spawned with position: ", player_to_add.global_position)


# Instantiate server player
func instantiate_player(message: Dictionary):
	var playername = "Pigeon with no name"
	var spawn_position: Vector3 = Vector3(message["data"]["pos"]["x"], message["data"]["pos"]["y"], message["data"]["pos"]["z"])

	var player_to_add = NetworkOrchestrator.small_props_spawner_node.spawn({
		"entity": "player",
		"player_scene_path": NetworkOrchestrator.player_scene_path,
		"player_name": playername,
		"player_spawn_position": spawn_position,
		"player_spawn_up": Vector3.UP,
		"authority_peer_id": 1
	})
	# player_to_add.global_rotation = Vector3(float(player.xr), float(player.yr), float(player.zr))
	# player_to_add.set_physics_process(false)
	players_list[message.player_id] = player_to_add
	players_list_last_movement[message.player_id] = spawn_position
	# if server_id != null:
	# 	player_to_add.label_server_name.text = NetworkOrchestrator.servers_list[server_id].name

	# print("Remnote player spawned with position: ", player_to_add.global_position)

func player_move(message: Dictionary):
	# print("================")
	# print(message["data"]["uuid"])
	# print(players_list.keys())
	if players_list.has(message["data"]["uuid"]):
		# print("YEAH!")
		var player = players_list[message["data"]["uuid"]]
		player.input_from_server.input_direction = Vector2(float(message["data"]["pos"]["x"]), float(message["data"]["pos"]["y"]))
		player.input_from_server.rotation = Vector3(
			float(message["data"]["rot"]["x"]), float(message["data"]["rot"]["y"]), float(message["data"]["rot"]["z"])
		)
		player.new_input_from_server = true

func _send_metrics():
	if servers_ticks_tasks.SendMetricsCurrent > 0:
		servers_ticks_tasks.SendMetricsCurrent -= 1
	else:
		if NetworkOrchestrator.metrics_enabled == true:
			var all_metrics = {
				"currentplayers": players_list.size(),
				"memory": Performance.get_monitor(Performance.MEMORY_STATIC),
				"numberobjects": Performance.get_monitor(Performance.OBJECT_COUNT),
				"timefps": Performance.get_monitor(Performance.TIME_FPS),
			}
			for proptype in props_list.keys():
				all_metrics["current" + proptype] = props_list[proptype].size()
			NetworkOrchestrator.mqtt_client_metrics.publish("metrics/server/" + NetworkOrchestrator.server_name, JSON.stringify(all_metrics))
		servers_ticks_tasks.SendMetricsCurrent = servers_ticks_tasks.SendMetricsReset


#########################
# Props                 #

func instantiate_props_remote_add(prop):
	_spawn_prop_remote_add(prop)

func instantiate_props_remote_update(prop):
	_spawn_prop_remote_update(prop)

func _spawn_prop_remote_add(prop):
	# print("Create prop: ", prop)
	# add prop
	if not props_list.has(prop.type):
		return
	var uuid = UUID_UTIL.v4()
	var prop_instance: RigidBody3D = NetworkOrchestrator.get_spawnable_props_newinstance(prop.type)
	NetworkOrchestrator.props_list[prop.type][uuid] = prop_instance
	prop_instance.spawn_position = Vector3(float(prop.x), float(prop.y), float(prop.z))
	prop_instance.set_physics_process(false)
	NetworkOrchestrator.small_props_spawner_node.get_node(
		NetworkOrchestrator.small_props_spawner_node.spawn_path
	).call_deferred("add_child", prop_instance, true)
	NetworkOrchestrator.props_list[prop.type][uuid] = prop_instance

func _spawn_prop_remote_update(prop):
	if not NetworkOrchestrator.props_list[prop.type].has(prop.uuid):
		return
	# update the position
	NetworkOrchestrator.props_list[prop.type][prop.uuid].global_position = Vector3(float(prop.x), float(prop.y), float(prop.z))
	NetworkOrchestrator.props_list[prop.type][prop.uuid].global_rotation = Vector3(float(prop.xr), float(prop.yr), float(prop.zr))

func _send_props_to_sdo():
	# if servers_ticks_tasks.SendPropsToMQTTCurrent > 0:
	# 	servers_ticks_tasks.SendPropsToMQTTCurrent -= 1
	# else:
	# 	var propsData = []
	# 	var position = Vector3(0.0, 0.0, 0.0)
	# 	var rotation = Vector3(0.0, 0.0, 0.0)
	# 	for proptype in props_list.keys():
	# 		for uuid in props_list[proptype].keys():
	# 			position = props_list[proptype][uuid].global_position
	# 			rotation = props_list[proptype][uuid].global_rotation
	# 			if props_list_last_movement[proptype][uuid] != position or props_list_last_rotation[proptype][uuid] != rotation:
	# 				propsData.append({
	# 					"type": proptype,
	# 					"uuid": uuid,
	# 					"x": position[0],
	# 					"y": position[1],
	# 					"z": position[2],
	# 					"xr": rotation[0],
	# 					"yr": rotation[1],
	# 					"zr": rotation[2]
	# 				})
	# 				props_list_last_movement[proptype][uuid] = position
	# 				props_list_last_rotation[proptype][uuid] = rotation
	# 				# used for call save on persistance
	# 				if props_list[proptype][uuid].has_node("DataEntity"):
	# 					var dataentity = props_list[proptype][uuid].get_node("DataEntity")
	# 					dataentity.backgroud_save()
	# 	if propsData.size() > 0:
	# 		NetworkOrchestrator.mqtt_client_sdo.publish("sdo/propschanges", JSON.stringify({
	# 			"add": [],
	# 			"update": propsData,
	# 			"delete": [],
	# 			"server_id": NetworkOrchestrator.server_sdo_id,
	# 		}))
	# 	servers_ticks_tasks.SendPropsToMQTTCurrent = servers_ticks_tasks.SendPropsToMQTTReset
	pass

func set_server_inactive(_newserver_id: int):
	print("# Disable the server")
	NetworkOrchestrator.is_sdo_active = false
	# TODO send props to new server id
	# unload all
	print("Clean items")
	for uuid in NetworkOrchestrator.players_list.keys():
		NetworkOrchestrator.players_list[uuid].queue_free()
		NetworkOrchestrator.players_list.erase(uuid)
	for proptype in NetworkOrchestrator.props_list.keys():
		for uuid in NetworkOrchestrator.props_list[proptype].keys():
			NetworkOrchestrator.props_list[proptype][uuid].queue_free()
			NetworkOrchestrator.props_list[proptype].erase(uuid)
	for proptype in props_list.keys():
		for uuid in props_list[proptype].keys():
			props_list[proptype][uuid].queue_free()
			props_list[proptype].erase(uuid)









#####################################################
# Horizon server part                              #
#####################################################

func dispatch_horizon_message(message: Dictionary):
	if message['namespace'] == "server":
		match message['event']:
			"add_props":
				# print(message)
				for planet in message["data"]["planets"]:
					if not props_list["planets"].has(planet["uuid"]):
						# spawn planet
						var spawnable_planet_instance = planet_scene.instantiate()
						spawnable_planet_instance.spawn_position = Vector3(planet["position"]["x"], planet["position"]["y"], planet["position"]["z"])
						spawnable_planet_instance.name = planet.name
						spawnable_planet_instance.tree_entered.connect(func():
							spawnable_planet_instance.owner = get_tree().current_scene
						)
						universe_scene.add_child(spawnable_planet_instance)
						props_list["planets"][planet["uuid"]] = spawnable_planet_instance

				# manage player
				var player_data = message["data"]["player"]
				# print("Player data received: %s" % player_data)

				var spawned_entity_instance = player_scene.instantiate()
				spawned_entity_instance.spawn_position = Vector3(
					player_data["position"]["x"], player_data["position"]["y"], player_data["position"]["z"]
				)
				spawned_entity_instance.name = player_data["name"]

				spawned_entity_instance.tree_entered.connect(func():
					spawned_entity_instance.owner = get_tree().current_scene
				)
				universe_scene.add_child(spawned_entity_instance)
				spawned_entity_instance.set_uuid(player_data["uuid"])
				players_list[player_data["uuid"]] = spawned_entity_instance
				players_list_last_movement[player_data["uuid"]] = spawned_entity_instance.global_position
				players_list_last_rotation[player_data["uuid"]] = spawned_entity_instance.global_rotation
				spawned_entity_instance.connect("hs_server_move", _on_player_move)

			"add_prop":
				for type in message["data"].keys():
					match type:
						"box50cm":
							var box = message["data"][type]
							if Vector3(box["position"]["x"], box["position"]["y"], box["position"]["z"]) == Vector3.ZERO:
								if players_list.has(message["data"]["player_uuid"]):
									var player = players_list[message["data"]["player_uuid"]]
									var box_spawn_position: Vector3 = player.global_position + (-player.global_basis.z * 1.5) + player.global_basis.y * 2.0
									var spawn_position: Vector3 = box_spawn_position
									var spawn_rotation: Vector3 = player.global_transform.basis.y.normalized()
									var data =  {
										"x": spawn_position.x,
										"y": spawn_position.y,
										"z": spawn_position.z,
										"rx": spawn_rotation.x,
										"ry": spawn_rotation.y,
										"rz": spawn_rotation.z,
									}

									# spawn box50cm
									var spawnable_box50cm_instance = box50cm_scene.instantiate()
									spawnable_box50cm_instance.spawn_position = Vector3(data["x"], data["y"], data["z"])
									# spawnable_box50cm_instance.name = box["uuid"]
									spawnable_box50cm_instance.uuid = box["uuid"]
									spawnable_box50cm_instance.tree_entered.connect(func():
										spawnable_box50cm_instance.owner = get_tree().current_scene
									)
									universe_scene.add_child(spawnable_box50cm_instance)
									props_list_last_movement[box["uuid"]] = Vector3.ZERO
									props_list_last_rotation[box["uuid"]] = Vector3.ZERO
									spawnable_box50cm_instance.connect("hs_server_prop_move", _on_prop_move)
									props_list["box50cm"][box["uuid"]] = spawnable_box50cm_instance
							else:
								# spawn box50cm
								var spawnable_box50cm_instance = box50cm_scene.instantiate()
								spawnable_box50cm_instance.spawn_position = Vector3(box["position"]["x"], box["position"]["y"], box["position"]["z"])
								spawnable_box50cm_instance.global_rotation = Vector3(box["rotation"]["x"], box["rotation"]["y"], box["rotation"]["z"])
								# spawnable_box50cm_instance.name = box["uuid"]
								spawnable_box50cm_instance.uuid = box["uuid"]
								spawnable_box50cm_instance.tree_entered.connect(func():
									spawnable_box50cm_instance.owner = get_tree().current_scene
								)
								universe_scene.add_child(spawnable_box50cm_instance)
								spawnable_box50cm_instance.connect("hs_server_prop_move", _on_prop_move)
								props_list["box50cm"][box["uuid"]] = spawnable_box50cm_instance

						"player_uuid":
							# only used to spawn something by the player
							pass
						_:
							print("Unknown prop type: " + type)
			"delete_player":
				var player_uuid = message["data"]["uuid"]
				if players_list.has(player_uuid):
					var player = players_list[player_uuid]
					player.queue_free()
					players_list.erase(player_uuid)
					players_list_last_movement.erase(player_uuid)
					players_list_last_rotation.erase(player_uuid)
			_:
				print("Unknown server event: " + message['event'])
	elif message['namespace'] == "player":
		match message['event']:
			"spawn":
				instantiate_player(message)
			"move":
				player_move(message)

func _on_player_move(client_uuid: String, position: Vector3, rotation: Vector3):
	if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if players_list_last_movement[client_uuid] != position or players_list_last_rotation[client_uuid] != rotation:
			players_newposition[client_uuid] = {
				"uuid": client_uuid,
				"pos": {
					"x": position[0],
					"y": position[1],
					"z": position[2]
				},
				"rot": {
					"x": rotation[0],
					"y": rotation[1],
					"z": rotation[2]
				}
			}
			players_list_last_movement[client_uuid] = position
			players_list_last_rotation[client_uuid] = rotation

func send_players_newposition_to_horizon():
	if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if players_newposition.values().size() == 0:
			return
		debug_message_number = debug_message_number + 1
		var message = {
			"namespace": "players",
			"event": "position",
			"amessagenb": debug_message_number,
			"data": players_newposition.values()
		}
		peer.send_text(JSON.stringify(message))
		players_newposition.clear()

func _on_prop_move(uuid: String, position: Vector3, rotation: Vector3, type: String):
	if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if props_list_last_movement[uuid] != position or props_list_last_rotation[uuid] != rotation:
			props_newposition[uuid] = {
				"uuid": uuid,
				"pos": {
					"x": position[0],
					"y": position[1],
					"z": position[2]
				},
				"rot": {
					"x": rotation[0],
					"y": rotation[1],
					"z": rotation[2]
				},
				"type": type,
			}
			props_list_last_movement[uuid] = position
			props_list_last_rotation[uuid] = rotation

func send_props_newposition_to_horizon():
	if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if props_newposition.values().size() == 0:
			return
		debug_message_number = debug_message_number + 1
		var message = {
			"namespace": "props",
			"event": "position",
			"amessagenb": debug_message_number,
			"data": props_newposition.values()
		}
		peer.send_text(JSON.stringify(message))
		props_newposition.clear()
