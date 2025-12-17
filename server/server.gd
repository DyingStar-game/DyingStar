extends Node

signal populated_universe

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

# conversion of position to prevent collision problems when position is so far from origin
const POSITION_CONVERSION_X = 0.0 #18999498785.9
const POSITION_CONVERSION_Y = 0.0
const POSITION_CONVERSION_Z = 0.0

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
var props_update: Dictionary = {}

var player_scene_path: String = "res://scenes/normal_player/normal_player.tscn"

var player_scene: PackedScene = preload("res://scenes/normal_player/normal_player.tscn")
var box50cm_scene: PackedScene = preload("res://scenes/props/testbox/box_50cm.tscn")
var props_scene: Dictionary = {
	'scenes/props/StorageBoxes/container_benne_1200x240x240.tscn':
		preload('res://scenes/props/StorageBoxes/container_benne_1200x240x240.tscn'),
	'scenes/props/StorageBoxes/container_liquid_1200x240x240.tscn':
		preload('res://scenes/props/StorageBoxes/container_liquid_1200x240x240.tscn'),
	'scenes/props/StorageBoxes/container_plate_1200x240x30.tscn':
		preload('res://scenes/props/StorageBoxes/container_plate_1200x240x30.tscn'),
	'scenes/props/StorageBoxes/container_standard_a_1200x240x240.tscn':
		preload('res://scenes/props/StorageBoxes/container_standard_a_1200x240x240.tscn'),
	'scenes/props/StorageBoxes/container_standard_b_1200x240x240.tscn':
		preload('res://scenes/props/StorageBoxes/container_standard_b_1200x240x240.tscn'),
	'scenes/props/StorageBoxes/pallet_benne_120x80x100.tscn':
		preload('res://scenes/props/StorageBoxes/pallet_benne_120x80x100.tscn'),
	'scenes/props/StorageBoxes/pallet_crate_120x80x100.tscn':
		preload('res://scenes/props/StorageBoxes/pallet_crate_120x80x100.tscn'),
	'scenes/props/StorageBoxes/pallet_liquid_120x80x100.tscn':
		preload('res://scenes/props/StorageBoxes/pallet_liquid_120x80x100.tscn'),
	# 'scenes/props/StorageBoxes/pallet_plate_120x80x100.tscn': preload('res://scenes/props/StorageBoxes/pallet_plate_120x80x100.tscn'),
	'scenes/props/rock/rock_mining_01.tscn':
		preload('res://scenes/props/rock/rock_mining_01.tscn'),
	'scenes/props/testbox/box_50cm.tscn':
		preload('res://scenes/props/testbox/box_50cm.tscn'),
	'scenes/props/testbox/box_4m.tscn':
		preload('res://scenes/props/testbox/box_4m.tscn'),
	# 'scenes/props/city/sandbox_capital.tscn': preload('res://scenes/props/city/sandbox_capital.tscn'),
}

var debug_message_number: int = 0

var serverinfo_uuid: String = ""

func _enter_tree() -> void:
	NetworkOrchestrator.load_server_config()

func _ready() -> void:
	set_process(false)
	_send_metrics()

func _physics_process(_delta: float) -> void:
	send_players_newposition_to_horizon()
	send_props_update_to_horizon()

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

	if ServerNetwork.start_websocket_server():
		set_process(true)
	ServerNetwork._init_server_network_devmode()

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
	if players_list.has(message["player_id"]):
		# print("YEAH!")
		var player = players_list[message["player_id"]]
		player.input_from_server.input_direction = Vector2(float(message["data"]["pos"]["x"]), float(message["data"]["pos"]["y"]))
		player.input_from_server.rotation = Vector3(
			float(message["data"]["rot"]["x"]), float(message["data"]["rot"]["y"]), float(message["data"]["rot"]["z"])
		)
		player.new_input_from_server = true
	else:
		print("Player move not found: " + str(message["player_id"]))


func player_action(message: Dictionary):
	if players_list.has(message["player_id"]):
		var player = players_list[message["player_id"]]
		player.server_action_received(message["data"])


func _send_metrics():
	while true:
		await get_tree().create_timer(1.0).timeout
		if not serverinfo_uuid == "":
			var nb_scenes = 0
			for proptype in props_list.keys():
				nb_scenes += props_list[proptype].size()
			var message = {
				"namespace": "props",
				"event": "position",
				"amessagenb": 0,
				"data": [
					{
						"uuid": serverinfo_uuid,
						"type": "serverinfo",
						"fps": Performance.get_monitor(Performance.TIME_FPS),
						"objects_number": Performance.get_monitor(Performance.OBJECT_COUNT),
						"players_number": players_list.size(),
						"scenes_number": nb_scenes,
					}
				]
			}
			# print("Send server metrics to horizon: ", message)
			ServerNetwork.send_message(message, "prop_update")

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

func create_vector3_with_conversion_hg(x: float, y: float, z: float) -> Vector3:
	return Vector3(
		x - POSITION_CONVERSION_X,
		y - POSITION_CONVERSION_Y,
		z - POSITION_CONVERSION_Z
	)

func convert_value_to_universe(value: float, conversion: float) -> float:
	return value + conversion




func _on_player_move(client_uuid: String, position: Vector3, rotation: Vector3, reparent_uuid = null, _is_parented = false):
	# if client_uuid == "024255cb-a567-4fc0-8126-fe6f8c32054c":
	# 	print("move uuid:", client_uuid)
	if players_list_last_movement[client_uuid] != position or players_list_last_rotation[client_uuid] != rotation:
		# Prevent write over reparent (because reparent will not sent to client)
		if players_newposition.has(client_uuid) and players_newposition[client_uuid].has("reparent"):
			return
		players_newposition[client_uuid] = {
			"player_id": client_uuid,
			"pos": {
				"x": convert_value_to_universe(position[0], POSITION_CONVERSION_X),
				"y": convert_value_to_universe(position[1], POSITION_CONVERSION_Y),
				"z": convert_value_to_universe(position[2], POSITION_CONVERSION_Z)
			},
			"rot": {
				"x": rotation[0],
				"y": rotation[1],
				"z": rotation[2]
			}
		}

		if reparent_uuid != null:
			players_newposition[client_uuid]["reparent"] = reparent_uuid
		players_list_last_movement[client_uuid] = position
		players_list_last_rotation[client_uuid] = rotation

func send_players_newposition_to_horizon():
	if players_newposition.values().size() == 0:
		return
	debug_message_number = debug_message_number + 1
	# print("Send players to horizon: ", players_newposition.values().size())
	var message = {
		"namespace": "players",
		"event": "position",
		"amessagenb": debug_message_number,
		"data": players_newposition.values()
	}
	# print("[server] Send players newposition to horizon")
	ServerNetwork.send_message(message, "player_position")
	players_newposition.clear()

func _on_prop_update(
	uuid: String,
	properties: Dictionary,
	type: String,
	is_parented = false
):
	if not props_update.has(uuid):
		props_update[uuid] = {
			"uuid": uuid,
			"type": type,
		}
	var prop_entry = props_update[uuid]
	for key in properties.keys():
		if key == "position":
			if is_parented == true:
				prop_entry['position'] = {
					"x": properties["position"][0],
					"y": properties["position"][1],
					"z": properties["position"][2]
				}
			else:
				prop_entry['position'] = {
					"x": convert_value_to_universe(properties["position"][0], POSITION_CONVERSION_X),
					"y": convert_value_to_universe(properties["position"][1], POSITION_CONVERSION_Y),
					"z": convert_value_to_universe(properties["position"][2], POSITION_CONVERSION_Z)
				}
		elif key == "rotation":
			prop_entry['rotation'] = {
				"x": properties["rotation"][0],
				"y": properties["rotation"][1],
				"z": properties["rotation"][2]
			}
		else:
			prop_entry[key] = properties[key]

func send_props_update_to_horizon():
	if props_update.values().size() == 0:
		return
	debug_message_number = debug_message_number + 1
	var message = {
		"namespace": "props",
		"event": "position",
		"amessagenb": debug_message_number,
		"data": props_update.values()
	}
	# print("Send props update to horizon: ", message)
	ServerNetwork.send_message(message, "prop_update")
	props_update.clear()

func _on_prop_delete(
	uuid: String,
	type: String
):
	debug_message_number = debug_message_number + 1
	var message = {
		"namespace": "props",
		"event": "delete_object",
		"amessagenb": debug_message_number,
		"data": [
			{
				"uuid": uuid,
				"type": type,
			}
		]
	}
	ServerNetwork.send_message(message, "prop_delete")
	props_update.erase(uuid)
	if props_list.has(type):
		if props_list[type].has(uuid):
			props_list[type].erase(uuid)
	if props_list_last_movement.has(uuid):
		props_list_last_movement.erase(uuid)
	if props_list_last_rotation.has(uuid):
		props_list_last_rotation.erase(uuid)

func create_planet(event: Dictionary) -> void:
	# spawn planet
	var planet_data = event["data"]["object_data"]

	var spawnable_planet_instance = load("res://" + planet_data["scenename"]).instantiate()
	spawnable_planet_instance.spawn_position = create_vector3_with_conversion_hg(
		planet_data["positions"][0]["x"],
		planet_data["positions"][0]["y"],
		planet_data["positions"][0]["z"]
	)
	spawnable_planet_instance.name = planet_data["name"]
	spawnable_planet_instance.uuid = event["data"]["object_uuid"]
	spawnable_planet_instance.tree_entered.connect(func():
		spawnable_planet_instance.owner = get_tree().current_scene
	)
	universe_scene.add_child(spawnable_planet_instance)
	props_list_last_movement[event["data"]["object_uuid"]] = Vector3.ZERO
	props_list_last_rotation[event["data"]["object_uuid"]] = Vector3.ZERO
	props_list["planets"][event["data"]["object_uuid"]] = spawnable_planet_instance

func create_player(event: Dictionary) -> void:
	prints("Creating player on server side: %s" % event)
	var player_data = event["data"]["object_data"]
	# var player_uuid = message["data"]["object_uuid"]
	var player_uuid = event["data"]["object_data"]["connection_id"]

	# print("Player data received: %s" % player_data)

	var spawned_entity_instance = player_scene.instantiate()
	spawned_entity_instance.name = player_data["name"]

	var parented = false
	if player_data["parent_id"] != "":
		var parent = _search_parent_node(player_data["parent_id"])
		if parent != null:
			parented = true
			parent.add_child(spawned_entity_instance)

	if not parented:
		universe_scene.add_child(spawned_entity_instance)

	# TODO: move this to the backend later to decide where the player should be spawned
	#var spawn_planet = universe_scene.get_node("Sandbox") as Planet
	#if spawn_planet:
		#var spawn_transform = spawn_planet.get_spawn_point()
		##if player_data["parent_id"] != "":
			##var planet = _search_parent_node(player_data["parent_id"])
			##spawned_entity_instance.reparent(planet)
		#spawned_entity_instance.reparent(spawn_planet)
#
		#prints("position", spawn_transform.origin)
		#spawned_entity_instance.position = spawn_transform.origin
		
	#spawned_entity_instance.position = Vector3(
		#player_data["position"]["x"],
		#player_data["position"]["y"],
		#player_data["position"]["z"]
	#)

	spawned_entity_instance.set_uuid(player_uuid)
	players_list[player_uuid] = spawned_entity_instance
	prints("spawning player", player_uuid, "at", spawned_entity_instance.global_position)

	players_list_last_movement[player_uuid] = spawned_entity_instance.global_position
	players_list_last_rotation[player_uuid] = spawned_entity_instance.global_rotation

	spawned_entity_instance.connect("hs_server_move", _on_player_move)
	spawned_entity_instance.connect("hs_server_player_update", _on_player_update)

func set_serverinfo(event: Dictionary) -> void:
	serverinfo_uuid = event["data"]["object_uuid"]

func create_generic_object(event: Dictionary) -> void:
	# spawn genericprops
	var object_data = event["data"]["object_data"]
	var prop_scene: PackedScene
	if props_scene.has(object_data["scenename"]):
		prop_scene = props_scene[object_data["scenename"]]
	else:
		prop_scene = load("res://" + object_data["scenename"])

	var spawnable_prop_instance = prop_scene.instantiate()
	spawnable_prop_instance.set_physics_process(false)
	spawnable_prop_instance.spawn_position = create_vector3_with_conversion_hg(
		object_data["position"]["x"],
		object_data["position"]["y"],
		object_data["position"]["z"]
	)
	spawnable_prop_instance.uuid = event["data"]["object_uuid"]
	spawnable_prop_instance.tree_entered.connect(func():
		spawnable_prop_instance.owner = get_tree().current_scene
	)

	if object_data.has("parent_id"):
		if object_data["parent_id"] != "":
			var parent = _search_parent_node(object_data["parent_id"])
			if parent != null:
				parent.add_child(spawnable_prop_instance)
			else:
				universe_scene.add_child(spawnable_prop_instance)
		else:
			universe_scene.add_child(spawnable_prop_instance)
	else:
		universe_scene.add_child(spawnable_prop_instance)

	spawnable_prop_instance.client_channel_data_update(object_data)
	spawnable_prop_instance.connect("hs_server_prop_update", _on_prop_update)
	spawnable_prop_instance.connect("hs_server_prop_delete", _on_prop_delete)

	props_list_last_movement[event["data"]["object_uuid"]] = Vector3.ZERO
	props_list_last_rotation[event["data"]["object_uuid"]] = Vector3.ZERO
	if not props_list.has(event["data"]["object_type"]):
		props_list[event["data"]["object_type"]] = {}
	props_list[event["data"]["object_type"]][event["data"]["object_uuid"]] = spawnable_prop_instance
	spawnable_prop_instance.set_physics_process(true)

func _search_parent_node(parent_id: String) -> Node:
	for proptype in props_list.keys():
		if props_list[proptype].has(parent_id):
			return props_list[proptype][parent_id]
	return null

func _on_player_update(
	client_uuid: String,
	properties: Dictionary,
):
	var message = {
		"namespace": "players",
		"event": "update",
		"uuid": client_uuid,
		"data": properties
	}
	ServerNetwork.send_message(message, "player_update")
