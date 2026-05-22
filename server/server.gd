extends Node

signal populated_universe

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")
## Tick interval (frames) for the active-body chunk-pin sweep.
const PIN_TICK_INTERVAL: int = 6
## Prop type names in props_list that may contain RigidBody3D instances
## we want to pin chunks for.  "planets" intentionally excluded.
const PIN_PROP_TYPES: Array[String] = ["box50cm", "box4m", "ship"]
## Max number of [Pin] log entries before suppressing further output.
const PIN_DEBUG_MAX: int = 200

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
var players_list_creationdate = {}
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
	'scenes/props/city/sandbox_capital.tscn':
		preload('res://scenes/props/city/sandbox_capital.tscn'),
}

var debug_message_number: int = 0

var serverinfo_uuid: String = ""
var serverinfo_name: String = ""

# on server, Horizon messages can arrives in not right order when have parent_id for players
# so we store the message in this case in the goal to process them later
var pending_messages_player_parenting: Array[Dictionary] = []
# same for generic objects
var pending_messages_generic_objects_parenting: Array[Dictionary] = []
var pending_freeze_objects: Array[Dictionary] = []
var check_pending_objects_timer: int = 0
var check_out_of_zone_after_split: int = 0

## True once manage_zone() has received an authoritative zone assignment
## from Horizon.  Until then, planets keep zero resident chunks (only their
## safety-net coarse mesh) so a 17-planet boot doesn't load 836k shapes.
var _zone_initialized: bool = false

## Tick counter for the active-body chunk-pin sweep.  Runs every
## PIN_TICK_INTERVAL frames in _process to refresh which planet chunks
## must stay resident because an awake RigidBody3D is sitting on them.
var _pin_tick_counter: int = 0
## Number of debug lines printed by the pin sweep so far (capped to keep
## logs readable).  Reset/incremented in _pin_node_to_planet_chunk.
var _pin_debug_logged: int = 0


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

	# Active-body chunk pinning.  At ~60 fps this fires every ~100 ms,
	# refreshing which planet chunks must stay resident because an awake
	# RigidBody3D is sitting on them.  See _refresh_active_body_pins().
	_pin_tick_counter += 1
	if _pin_tick_counter >= PIN_TICK_INTERVAL:
		_pin_tick_counter = 0
		_refresh_active_body_pins()


## Sweep all RigidBody3D-based props, identify the planet chunk under
## each awake body, and push the resulting per-planet pin set so those
## chunks stay resident regardless of the zone's desired residency.
##
## Awake = (not sleeping) AND (not frozen).  Frozen / sleeping bodies do
## not need collision and may be evicted with the rest of the zone churn.
##
## Players (CharacterBody3D) are ALWAYS pinned regardless of
## _zone_initialized: in single-server / no-mesh deployments Horizon never
## sends a manage_zone() event, so without this fallback the per-chunk
## collision never loads and the player falls through onto the
## safety-net coarse mesh ~hundreds of metres below the visible surface.
func _refresh_active_body_pins() -> void:
	if props_list["planets"].is_empty():
		return
	if _zone_initialized == false and players_list.is_empty():
		return

	# planet_node → Dictionary[chunk_key, true]
	var pins_by_planet: Dictionary = {}
	for puuid in props_list["planets"].keys():
		pins_by_planet[puuid] = {}

	# Pin chunks under each connected player so their surroundings have
	# real collision even before (or without) a Horizon zone assignment.
	for player_uuid in players_list.keys():
		var player_node = players_list[player_uuid]
		if not is_instance_valid(player_node):
			continue
		if not (player_node is Node3D):
			continue
		_pin_node_to_planet_chunk(player_node as Node3D, pins_by_planet)

	if _zone_initialized:
		for ptype in PIN_PROP_TYPES:
			if not props_list.has(ptype):
				continue
			for body_uuid in props_list[ptype].keys():
				var body = props_list[ptype][body_uuid]
				if not is_instance_valid(body):
					continue
				if not (body is RigidBody3D):
					continue
				var rb: RigidBody3D = body
				if rb.freeze:
					continue
				if rb.sleeping:
					continue
				_pin_node_to_planet_chunk(rb, pins_by_planet)

	# Push pin set to each planet (empty array clears pins).
	for puuid in pins_by_planet.keys():
		var planet_node = props_list["planets"][puuid]
		if planet_node == null or not is_instance_valid(planet_node):
			continue
		if not (planet_node is Planet):
			continue
		var planet: Planet = planet_node as Planet
		if planet.planet_terrain == null:
			continue
		var keys := PackedStringArray()
		for k in pins_by_planet[puuid].keys():
			keys.append(k as String)
		planet.planet_terrain.set_pinned_chunks(keys)


## Find the closest planet to [param body] and add the chunk key under
## the body's position to [param pins_by_planet][planet_uuid].  Skips when
## the body is far above any planet (>radius * 1.5 from any centre).
func _pin_node_to_planet_chunk(body: Node3D, pins_by_planet: Dictionary) -> void:
	var best_uuid := ""
	var best_planet: Planet = null
	var best_dist_sq := INF
	var body_pos := body.global_position
	for puuid in props_list["planets"].keys():
		var pn = props_list["planets"][puuid]
		if pn == null or not is_instance_valid(pn) or not (pn is Planet):
			continue
		var p: Planet = pn as Planet
		if p.planet_data == null:
			continue
		var d_sq: float = body_pos.distance_squared_to(p.global_position)
		# Skip planets clearly out of reach (1.5× radius gives margin for
		# atmosphere / above-surface bodies that should still pin).
		var max_r: float = p.planet_data.radius * 1.5
		if d_sq > max_r * max_r:
			continue
		if d_sq < best_dist_sq:
			best_dist_sq = d_sq
			best_uuid = puuid
			best_planet = p
	if best_planet == null:
		if _pin_debug_logged < PIN_DEBUG_MAX:
			_pin_debug_logged += 1
			print("[Pin] no planet near body at ", body_pos,
				" (closest planets: ", _debug_closest_planets(body_pos, 3), ")")
		return
	var local := body_pos - best_planet.global_position
	if local.length_squared() < 1.0e-6:
		return
	# Convert from world-frame to planet-LOCAL (body-frame) direction.
	# vec2pix_nest expects the direction in the planet's own coordinate
	# system; the planet rotates in orbit, so a world-frame direction would
	# resolve to the WRONG tile and the actual tile under the player would
	# never be pinned (player falls through to safety net).
	var local_body: Vector3 = best_planet.global_transform.basis.inverse() * local
	var dir := local_body.normalized()
	var nside: int = best_planet.planet_data.export_nside
	var ipix: int = HEALPix.vec2pix_nest(nside, dir)
	var key := "hp_n%d_p%d" % [nside, ipix]
	pins_by_planet[best_uuid][key] = true
	if _pin_debug_logged < PIN_DEBUG_MAX:
		_pin_debug_logged += 1
		var alt: float = sqrt(best_dist_sq) - best_planet.planet_data.radius
		print("[Pin] body at ", body_pos, " → planet '", best_planet.name,
			"' alt=", alt, " m  key=", key)


## Helper for debug log: list the N closest planets and their distances.
func _debug_closest_planets(pos: Vector3, n: int) -> String:
	var items: Array = []
	for puuid in props_list["planets"].keys():
		var pn = props_list["planets"][puuid]
		if not is_instance_valid(pn) or not (pn is Planet):
			continue
		var p: Planet = pn as Planet
		var d := pos.distance_to(p.global_position)
		var r: float = p.planet_data.radius if p.planet_data else 0.0
		items.append([d, p.name, r])
	items.sort_custom(func(a, b): return a[0] < b[0])
	var out := ""
	for i in range(min(n, items.size())):
		out += "%s d=%.0f r=%.0f; " % [items[i][1], items[i][0], items[i][2]]
	return out

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
		if message.has("object_data"):
			player.server_action_received(message["object_data"])
		else:
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
			print("erase player (2): %s" % client_uuid)
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
	_is_parented = false
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
	print("Send props update to horizon: ", message)
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
	var planet_uuid: String = event["data"]["object_uuid"]

	# Guard: planet may already exist (Horizon re-sends initial_object for each
	# connecting player). Creating a duplicate would load thousands of collision
	# shapes again and exhaust Godot's physics RID pool.
	if props_list["planets"].has(planet_uuid):
		print("[server] create_planet: planet '%s' already spawned, skipping." % planet_uuid)
		return

	var spawnable_planet_instance = load("res://" + planet_data["scenename"]).instantiate()
	spawnable_planet_instance.spawn_position = Vector3(
		planet_data["positions"][0]["x"],
		planet_data["positions"][0]["y"],
		planet_data["positions"][0]["z"]
	)
	spawnable_planet_instance.name = planet_data["name"]
	spawnable_planet_instance.uuid = planet_uuid
	spawnable_planet_instance.tree_entered.connect(func():
		spawnable_planet_instance.owner = get_tree().current_scene
	)
	universe_scene.add_child(spawnable_planet_instance)
	props_list_last_movement[planet_uuid] = Vector3.ZERO
	props_list_last_rotation[planet_uuid] = Vector3.ZERO
	props_list["planets"][planet_uuid] = spawnable_planet_instance

	# Once the planet's terrain reports its safety-net + collision root is
	# ready, push the current zone's chunk residency.  If the zone hasn't
	# been assigned yet, _push_zone_residency_to_planet is a no-op and the
	# upcoming manage_zone() call will fan out residency to every planet.
	var on_ready := func():
		_push_zone_residency_to_planet(spawnable_planet_instance)
	if spawnable_planet_instance.planet_terrain != null:
		spawnable_planet_instance.planet_terrain.initial_chunks_ready.connect(
			on_ready, CONNECT_ONE_SHOT)
	else:
		# Wait one frame for terrain to be assigned, then connect.
		spawnable_planet_instance.ready.connect(func():
			if spawnable_planet_instance.planet_terrain != null:
				spawnable_planet_instance.planet_terrain.initial_chunks_ready.connect(
					on_ready, CONNECT_ONE_SHOT))

func update_planet(event: Dictionary) -> void:
	if props_list["planets"].has(event["object_uuid"]):
		var planet = props_list["planets"][event["object_uuid"]]
		# TODO update on server the data


## Handle a biome update from Horizon.  Rebuilds collision shapes on the
## affected planet's chunks.
## Expected message format:
##   { "namespace": "server", "event": "update_biome",
##     "data": { "planet_uuid": "...",
##               "biome_type": "cave"/"road"/...,
##               "action": "add"/"remove",
##               "geometry": { "type": "linear"/"polygon"/"point",
##                             "vertices": [[lon,lat], ...],
##                             "width": 10.0, "depth": 5.0 },
##               "affected_chunks": ["hp_n64_p120", ...] (optional)
##     } }
func update_planet_biome(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var planet_uuid: String = data.get("planet_uuid", "")
	if planet_uuid.is_empty():
		push_warning("[server] update_planet_biome: missing planet_uuid")
		return

	if not props_list["planets"].has(planet_uuid):
		push_warning("[server] update_planet_biome: planet '%s' not found" % planet_uuid)
		return

	var planet_node: Node = props_list["planets"][planet_uuid]
	if not planet_node is Planet:
		push_warning("[server] update_planet_biome: node is not a Planet")
		return

	var planet: Planet = planet_node as Planet
	if planet.planet_terrain == null:
		push_warning("[server] update_planet_biome: planet has no PlanetTerrain")
		return

	var biome_update := {
		"biome_type": data.get("biome_type", ""),
		"action": data.get("action", "add"),
		"geometry": data.get("geometry", {}),
	}

	# Determine affected chunks: either provided by Horizon or computed via HEALPix.
	var chunk_keys: Array = []
	if data.has("affected_chunks") and not data["affected_chunks"].is_empty():
		chunk_keys = data["affected_chunks"]
	else:
		var geometry: Dictionary = data.get("geometry", {})
		var vertices: Array = geometry.get("vertices", [])
		if vertices.is_empty():
			push_warning("[server] update_planet_biome: no vertices and no affected_chunks")
			return
		var nside: int = planet.planet_data.export_nside
		var affected_ipix := HEALPix.query_polygon_pixels(nside, vertices)
		for ipix in affected_ipix:
			chunk_keys.append("hp_n%d_p%d" % [nside, ipix])

	print("[server] update_planet_biome: planet=%s chunks=%d biome=%s action=%s" % [
		planet.name, chunk_keys.size(), biome_update.biome_type, biome_update.action])
	planet.planet_terrain.rebuild_chunks(chunk_keys, biome_update)


func create_player(event: Dictionary) -> void:
	var player_uuid = ""
	if event["data"].has("object_uuid"):
		player_uuid = event["data"]["object_uuid"]
	else:
		prints("ERROR: No player UUID found in event: %s" % event)
		return

	if players_list.has(player_uuid):
		prints("Player already exists on server side: %s" % event)
		return

	prints("Creating player on server side: %s" % event)
	prints("Y A RIEN LA? player_uuid : %s", player_uuid)
	var player_data = event["data"]["object_data"]

	if player_data["parent_id"] != "" and _search_parent_node(player_data["parent_id"]) == null:
		# store pending message
		pending_messages_player_parenting.append(event)
		print("Pending message for player %s because parent_id %s not found yet" % [event["data"]["object_uuid"], player_data["parent_id"]])
		return

	# print("Player data received: %s" % player_data)
	players_list_creationdate[player_uuid] = Time.get_ticks_msec() + 5000

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
	# Derive the surface-normal "up" from the spawn position so the player is
	# oriented correctly on the planet surface, not stuck with global Vector3.UP.
	if not spawned_entity_instance.position.is_zero_approx():
		spawned_entity_instance.spawn_up = spawned_entity_instance.global_position.normalized()

	spawned_entity_instance.set_uuid(player_uuid)
	players_list.set(player_uuid, spawned_entity_instance)
	prints("spawning player", player_uuid, "at", spawned_entity_instance.global_position)

	players_list_last_movement[player_uuid] = spawned_entity_instance.global_position
	players_list_last_rotation[player_uuid] = spawned_entity_instance.global_rotation

	spawned_entity_instance.connect("hs_server_move", _on_player_move)
	spawned_entity_instance.connect("hs_server_player_update", _on_player_update)
	players_list_creationdate[player_uuid] = Time.get_ticks_msec() + 500

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

	if spawnable_prop_instance.has_signal("hs_server_prop_update"):
		spawnable_prop_instance.connect("hs_server_prop_update", _on_prop_update)
	else:
		push_warning("[Server] create_generic_object: scene '%s' root has no signal hs_server_prop_update (type=%s)" \
			% [object_data["scenename"], spawnable_prop_instance.get_class()])
	if spawnable_prop_instance.has_signal("hs_server_prop_delete"):
		spawnable_prop_instance.connect("hs_server_prop_delete", _on_prop_delete)
	else:
		push_warning("[Server] create_generic_object: scene '%s' root has no signal hs_server_prop_delete (type=%s)" \
			% [object_data["scenename"], spawnable_prop_instance.get_class()])
	# Must be after signals in case call signals if modifications done in client_channel_data_update
	spawnable_prop_instance.client_channel_data_update(object_data)

	props_list_last_movement[event["data"]["object_uuid"]] = Vector3.ZERO
	props_list_last_rotation[event["data"]["object_uuid"]] = Vector3.ZERO
	if not props_list.has(event["data"]["object_type"]):
		props_list[event["data"]["object_type"]] = {}
	props_list[event["data"]["object_type"]][event["data"]["object_uuid"]] = spawnable_prop_instance

	# check if position in zone, if not, freeze it
	var pos = spawnable_prop_instance.global_position
	if pos[0] < server_zone["x_start"] or pos[0] > server_zone["x_end"] \
			or pos[1] < server_zone["y_start"] or pos[1] > server_zone["y_end"] \
			or pos[2] < server_zone["z_start"] or pos[2] > server_zone["z_end"]:
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

func update_generic_object(event: Dictionary) -> void:
	var type = event["data"]["object_type"]
	if props_list[type].has(event["data"]["object_uuid"]):
		var object = props_list[type][event["data"]["object_uuid"]]
		object.client_channel_data_update(event["data"]["object_data"])


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

func remove_player(event: Dictionary) -> void:
	var player_uuid = event["data"]["object_uuid"]
	if players_list.has(player_uuid):
		var player = players_list[player_uuid]
		print("player has quit the game: %s" % player_uuid)
		players_list.erase(player_uuid)
		player.queue_free()

func freeze_object(event: Dictionary, append = true) -> bool:
	# we will freeze scenes objects
	print("Freeze object: %s" % event)
	var object = event["data"]
	if object["object_type"] == "planet":
		if props_list["planets"].has(object["object_uuid"]):
			var planet = props_list["planets"][object["object_uuid"]]
			planet.set_physics_process(false)
			return true
		if append:
			pending_freeze_objects.append(event)
			return false
		return false
	if object["object_type"] == "player":
		if players_list.has(object["object_uuid"]):
			var player = players_list[object["object_uuid"]]
			print("erase player (1): %s" % object["object_uuid"])
			players_list.erase(object["object_uuid"])
			player.queue_free()
			return true
		return false
			# if append:
			# 	pending_freeze_objects.append(event)
			# else:
			# 	return false
	if object["object_type"] == "star":
		# TODO not yet managed
		return false
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
			return false
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
	serverinfo_name = event["server_name"]
	check_out_of_zone_after_split = Time.get_ticks_msec() + 5000

	# Push HEALPix chunk residency to every spawned planet so collision
	# memory tracks our authoritative zone.  See _push_zone_residency_*.
	_zone_initialized = true
	_push_zone_residency_to_all()


## Compute the authoritative zone AABB in world space.
func _server_zone_aabb_world() -> AABB:
	var pmin := Vector3(
		server_zone["x_start"], server_zone["y_start"], server_zone["z_start"])
	var pmax := Vector3(
		server_zone["x_end"], server_zone["y_end"], server_zone["z_end"])
	return AABB(pmin, pmax - pmin)


## Push the current zone-derived chunk residency to one planet.
## No-op when zone is not yet initialised or planet has no terrain.
func _push_zone_residency_to_planet(planet_node: Node) -> void:
	if not _zone_initialized:
		return
	if planet_node == null or not is_instance_valid(planet_node):
		return
	if not (planet_node is Planet):
		return
	var planet: Planet = planet_node as Planet
	if planet.planet_terrain == null or planet.planet_data == null:
		return
	# Convert zone AABB from world → planet-local by subtracting planet origin.
	var aabb_world := _server_zone_aabb_world()
	var aabb_local := AABB(
		aabb_world.position - planet.global_position, aabb_world.size)
	var keys := planet.planet_data.chunks_in_aabb_world(aabb_local, 1)
	planet.planet_terrain.set_resident_chunks(keys)


## Push the current zone-derived chunk residency to every spawned planet.
func _push_zone_residency_to_all() -> void:
	if not _zone_initialized:
		return
	for planet_uuid in props_list["planets"].keys():
		_push_zone_residency_to_planet(props_list["planets"][planet_uuid])

func _check_out_of_zone(player_uuid: String = "") -> bool:
	if Time.get_ticks_msec() < check_out_of_zone_after_split:
		return false
	# check players position
	if players_list.has(player_uuid):
		if not players_list_creationdate.has(player_uuid):
			return false
		if Time.get_ticks_msec() < players_list_creationdate[player_uuid]:
			return false
		#print("go...")
		var pos = players_list[player_uuid].global_position
		var magicnumber = 0.400
		if pos[0] < (server_zone["x_start"] - magicnumber) or pos[0] > (server_zone["x_end"] + magicnumber) \
				or pos[1] < (server_zone["y_start"] - magicnumber) or pos[1] > (server_zone["y_end"] + magicnumber) \
				or pos[2] < (server_zone["z_start"] - magicnumber) or pos[2] > (server_zone["z_end"] + magicnumber):
			print("====== Player %s is out of zone at position %s" % [player_uuid, pos])
			print(server_zone)
			return true
	return false
