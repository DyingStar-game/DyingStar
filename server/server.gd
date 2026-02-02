extends Node

signal populated_universe

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

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

# on server, Horizon messages can arrives in not right order when have parent_id for players
# so we store the message in this case in the goal to process them later
var pending_messages_player_parenting: Array[Dictionary] = []
# same for generic objects
var pending_messages_generic_objects_parenting: Array[Dictionary] = []
var pending_freeze_objects: Array[Dictionary] = []
var check_pending_objects_timer: int = 0


func _enter_tree() -> void:
	NetworkOrchestrator.load_server_config()

func _ready() -> void:
	set_process(false)
	_send_metrics()

func _physics_process(_delta: float) -> void:
	send_players_newposition_to_horizon()
	send_props_update_to_horizon()

func _process(_delta: float) -> void:
	if check_pending_objects_timer == 10:
		# every 10 frames, check pending players parenting
		for pending_message in pending_messages_player_parenting.duplicate():
			if _search_parent_node(pending_message["data"]["object_data"]["parent_id"]) != null:
				print(
					"Processing pending message for player %s now that parent_id %s is available" % [
						pending_message["data"]["object_data"]["parent_id"],
						pending_message["data"]["object_uuid"]
					]
				)
				create_player(pending_message)
				pending_messages_player_parenting.erase(pending_message)

		# generic object created, now process pending messages for generic objects waiting for this generic object as parent
		for pending_message in pending_messages_generic_objects_parenting.duplicate():
			if _search_parent_node(pending_message["data"]["object_data"]["parent_id"]) != null:
				print(
					"Processing pending message for generic object %s now that parent_id %s is available" % [
						pending_message["data"]["object_uuid"],
						pending_message["data"]["object_data"]["parent_id"]
					]
				)
				create_generic_object(pending_message)
				pending_messages_generic_objects_parenting.erase(pending_message)
		
		# process pending freeze objects
		for pending_message in pending_freeze_objects.duplicate():
			var ret = freeze_object(pending_message, false)
			if ret == true:
				pending_freeze_objects.erase(pending_message)

		check_pending_objects_timer = 0
	else:
		check_pending_objects_timer += 1

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
						"fps": int(Performance.get_monitor(Performance.TIME_FPS)),
						"objects_number": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
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

func _on_player_move(client_uuid: String, position: Vector3, rotation: Vector3, reparent_uuid = null, _is_parented = false):
	# if client_uuid == "024255cb-a567-4fc0-8126-fe6f8c32054c":
	# 	print("move uuid:", client_uuid)
	if players_list_last_movement[client_uuid] != position or players_list_last_rotation[client_uuid] != rotation:
		# Prevent write over reparent (because reparent will not sent to client)
		if players_newposition.has(client_uuid) and players_newposition[client_uuid].has("reparent"):
			return

		var prep = {
			"player_id": client_uuid,
			"pos": {
				"x": position[0],
				"y": position[1],
				"z": position[2],
			},
			"rot": {
				"x": rotation[0],
				"y": rotation[1],
				"z": rotation[2]
			}
		}

		if reparent_uuid != null:
			prep["reparent"] = reparent_uuid
		players_list_last_movement[client_uuid] = position
		players_list_last_rotation[client_uuid] = rotation
		if _check_out_of_zone(client_uuid):
			prep["out_of_zone"] = serverinfo_uuid
			var player = players_list[client_uuid]
			players_list.erase(client_uuid)
			player.queue_free()
		players_newposition[client_uuid] = prep

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
			prop_entry['position'] = {
				"x": properties["position"][0],
				"y": properties["position"][1],
				"z": properties["position"][2]
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
	spawnable_planet_instance.spawn_position = Vector3(
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
	var player_uuid = ""
	if event["data"]["object_data"].has("connection_id"):
		player_uuid = event["data"]["object_data"]["connection_id"]
	elif event["data"].has("object_uuid"):
		player_uuid = event["data"]["object_uuid"]
	else:
		prints("ERROR: No player UUID found in event: %s" % event)
		return

	if players_list.has(player_uuid):
		prints("Player already exists on server side: %s" % event)
		return

	prints("Creating player on server side: %s" % event)
	var player_data = event["data"]["object_data"]

	if player_data["parent_id"] != "" and _search_parent_node(player_data["parent_id"]) == null:
		# store pending message
		pending_messages_player_parenting.append(event)
		print("Pending message for player %s because parent_id %s not found yet" % [event["data"]["object_uuid"], player_data["parent_id"]])
		return

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

	spawned_entity_instance.position = Vector3(
		player_data["position"]["x"],
		player_data["position"]["y"],
		player_data["position"]["z"]
	)

	spawned_entity_instance.set_uuid(player_uuid)
	players_list[player_uuid] = spawned_entity_instance
	prints("spawning player", player_uuid, "at", spawned_entity_instance.global_position)

	players_list_last_movement[player_uuid] = spawned_entity_instance.global_position
	players_list_last_rotation[player_uuid] = spawned_entity_instance.global_rotation

	spawned_entity_instance.connect("hs_server_move", _on_player_move)
	spawned_entity_instance.connect("hs_server_player_update", _on_player_update)

func set_serverinfo(uuid: String) -> void:
	serverinfo_uuid = uuid

func create_generic_object(event: Dictionary) -> void:
	# spawn genericprops
	var object_data = event["data"]["object_data"]

	if object_data.has("parent_id"):
		if object_data["parent_id"] != "" and _search_parent_node(object_data["parent_id"]) == null:
			# store pending message
			pending_messages_generic_objects_parenting.append(event)
			print("Pending message for object %s because parent_id %s not found yet" % [event["data"]["object_uuid"], object_data["parent_id"]])
			return

	var prop_scene: PackedScene
	if props_scene.has(object_data["scenename"]):
		prop_scene = props_scene[object_data["scenename"]]
	else:
		prop_scene = load("res://" + object_data["scenename"])

	var spawnable_prop_instance = prop_scene.instantiate()
	spawnable_prop_instance.set_physics_process(false)
	spawnable_prop_instance.spawn_position = Vector3(
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

	# check if position in zone, if not, freeze it
	var pos = spawnable_prop_instance.global_position
	if pos[0] < server_zone["x_start"] or pos[0] > server_zone["x_end"] or pos[1] < server_zone["y_start"] or pos[1] > server_zone["y_end"] or pos[2] < server_zone["z_start"] or pos[2] > server_zone["z_end"]:
		#  we are out of zone, keep it frozen
		spawnable_prop_instance.set_physics_process(false)
		if is_instance_of(spawnable_prop_instance, RigidBody3D):
			spawnable_prop_instance.freeze = true
	else:
		spawnable_prop_instance.set_physics_process(true)

	for pending_message in pending_messages_player_parenting.duplicate():
		if pending_message["data"]["object_data"]["parent_id"] == event["data"]["object_uuid"]:
			print(
				"Processing pending message for player %s now that parent_id %s is available" % [
					event["data"]["object_uuid"],
					pending_message["data"]["object_data"]["parent_id"]
				]
			)
			pending_messages_player_parenting.erase(pending_message)
			create_player(pending_message)

	# generic object created, now process pending messages for generic objects waiting for this generic object as parent
	for pending_message in pending_messages_generic_objects_parenting.duplicate():
		if pending_message["data"]["object_data"]["parent_id"] == event["data"]["object_uuid"]:
			print(
				"Processing pending message for generic object %s now that parent_id %s is available" % [
					pending_message["data"]["object_uuid"],
					pending_message["data"]["object_data"]["parent_id"]
				]
			)
			pending_messages_generic_objects_parenting.erase(pending_message)
			create_generic_object(pending_message)

func _search_parent_node(parent_id: String) -> Node:
	for proptype in props_list.keys():
		if props_list[proptype].has(parent_id):
			return props_list[proptype][parent_id]
	for player_id in players_list.keys():
		if player_id == parent_id:
			return players_list[player_id]
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

func freeze_object(event: Dictionary, append = true) -> bool:
	# we will freeze scenes objects
	var object = event["data"]
	if object["object_type"] == "planet":
		if props_list["planets"].has(object["object_uuid"]):
			var planet = props_list["planets"][object["object_uuid"]]
			planet.set_physics_process(false)
		else:
			if append:
				pending_freeze_objects.append(event)
			else:
				return false
	if object["object_type"] == "player":
		if players_list.has(object["object_uuid"]):
			var player = players_list[object["object_uuid"]]
			players_list.erase(object["object_uuid"])
			player.queue_free()
		else:
			if append:
				pending_freeze_objects.append(event)
			else:
				return false
	else:
		# other props
		var found = false
		for proptype in props_list.keys():
			if props_list[proptype].has(object["object_uuid"]):
				var prop = props_list[proptype][object["object_uuid"]]
				prop.set_physics_process(false)
				if is_instance_of(prop, RigidBody3D):
					prop.freeze = true
				found = true
				break
		if not found:
			if append:
				pending_freeze_objects.append(event)
			else:
				return false
	return true

func manage_zone(event: Dictionary) -> void:
	var zone_data = event["data"]
	server_zone["x_start"] = zone_data["min_x"]
	server_zone["x_end"] = zone_data["max_x"]
	server_zone["y_start"] = zone_data["min_y"]
	server_zone["y_end"] = zone_data["max_y"]
	server_zone["z_start"] = zone_data["min_z"]
	server_zone["z_end"] = zone_data["max_z"]

	set_serverinfo(event["server_uuid"])

func _check_out_of_zone(player_uuid: String = "") -> bool:
	# check players position
	if players_list.has(player_uuid):
		#print("go...")
		var pos = players_list[player_uuid].global_position
		if pos[0] < server_zone["x_start"] or pos[0] > server_zone["x_end"] or pos[1] < server_zone["y_start"] or pos[1] > server_zone["y_end"] or pos[2] < server_zone["z_start"] or pos[2] > server_zone["z_end"]:
			print("Player %s is out of zone at position %s" % [player_uuid, pos])
			return true
	return false
