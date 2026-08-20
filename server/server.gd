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

## Physics activity freeze (Part A — server FPS): a body that has SETTLED (negligible drift, so it
## stops jittering) AND is far from every player is frozen, so Jolt stops simulating it. It unfreezes
## as soon as a player comes within ACTIVE_RADIUS, so it stays pushable/mineable. Only bodies WE froze
## are unfrozen (design-frozen props — storage boxes, carried, in a bed — are left alone).
const SETTLE_EPS: float = 0.05       # m of net drift below which a body counts as "not moving"
const SETTLE_TICKS: int = 15         # consecutive still ticks (~1.5 s at the pin cadence) before freezing
const ACTIVE_RADIUS: float = 60.0    # m: keep bodies dynamic within this of any player

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
## Last frame uuid DECLARED to Horizon per player. Never assigned by a caller: it is a memo of what
## PropSpawn.parent_frame_uuid() returned last time, so a change of scene parent can be detected and
## re-announced. Same role as PropSync.server_last_parent_id for props.
var players_list_last_parent: Dictionary = {}
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
	"spawnbuilding": {},
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

var player_scene_path: String = "res://scenes/player/player.tscn"

var player_scene: PackedScene = preload("res://scenes/player/player.tscn")
var box50cm_scene: PackedScene = preload("res://scenes/_universe/props/containers/box_50cm.tscn")
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
	'scenes/_universe/structures/urban/cities/sandbox_capital.tscn':
		preload('res://scenes/_universe/structures/urban/cities/sandbox_capital.tscn'),
	'scenes/_universe/vehicles/ground/trucks/truck.tscn':
		preload('res://scenes/_universe/vehicles/ground/trucks/truck.tscn'),
	'scenes/_universe/structures/industrial/cargo_depot.tscn':
		preload('res://scenes/_universe/structures/industrial/cargo_depot.tscn'),
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

## Counter to throttle Horizon position/prop updates to every 2nd physics
## frame (30 messages/sec at 60 FPS physics).
var _horizon_update_counter: int = 0


func _enter_tree() -> void:
	NetworkOrchestrator.load_server_config()

func _ready() -> void:
	set_process(false)
	_send_metrics()

func _physics_process(_delta: float) -> void:
	_horizon_update_counter += 1
	if _horizon_update_counter >= 2:
		_horizon_update_counter = 0
		send_players_newposition_to_horizon()
		send_props_update_to_horizon()

func _process(_delta: float) -> void:
	if check_pending_objects_timer == 20:
		# every 20 frames, check pending players parenting
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
		_cull_settled_bodies()


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


## Physics activity freeze (Part A): freeze props that have SETTLED and are far from every player so
## Jolt stops simulating them (kills the resting-pile jitter cost); unfreeze them the moment a player
## comes within ACTIVE_RADIUS so they stay pushable/mineable. Only bodies WE froze are unfrozen —
## design-frozen props (storage boxes, carried, bed-loaded) and vehicles are left alone.
func _cull_settled_bodies() -> void:
	if not GameOrchestrator.is_server():
		return  # server-only: it owns the authoritative bodies
	for ptype in props_list.keys():
		if ptype == "planets" or not (props_list[ptype] is Dictionary):
			continue
		for body_uuid in props_list[ptype].keys():
			var body = props_list[ptype][body_uuid]
			if not _is_cullable_body(body):
				continue
			var rb: RigidBody3D = body
			if _player_within(rb.global_position, ACTIVE_RADIUS):
				if rb.freeze and rb.get_meta("_culled_frozen", false):
					_unfreeze_culled_body(rb)
				rb.set_meta("_settle_ticks", 0)
				continue
			if rb.freeze:
				continue  # already frozen (by us or by design), far → leave
			# Settle detection: drift from a reference point. Jitter oscillates within SETTLE_EPS so it
			# still counts as still; a real move pushes past it and resets the reference.
			# Measured in the PARENT's frame (the planet), never in world space: "settled" means "no
			# longer moving relative to the ground it rests on". A spinning planet sweeps a resting
			# prop through tens of metres of world space between refreshes, which would reset the
			# reference forever and stop the culler from ever freezing anything.
			var local_pos: Vector3 = rb.position
			var ref: Vector3 = rb.get_meta("_settle_ref", local_pos)
			var ticks: int = rb.get_meta("_settle_ticks", 0)
			if local_pos.distance_to(ref) < SETTLE_EPS:
				ticks += 1
			else:
				ticks = 0
				rb.set_meta("_settle_ref", local_pos)
			rb.set_meta("_settle_ticks", ticks)
			if ticks >= SETTLE_TICKS:
				_freeze_culled_body(rb)

## True if any connected player is within [param radius] of [param pos].
func _player_within(pos: Vector3, radius: float) -> bool:
	var r2 := radius * radius
	for puuid in players_list.keys():
		var p = players_list[puuid]
		if is_instance_valid(p) and p is Node3D and pos.distance_squared_to((p as Node3D).global_position) < r2:
			return true
	return false

## True if [param node] is a free physics prop the settle-culler may freeze/unfreeze: a live
## RigidBody3D that is not a Vehicle and not carried/bed-loaded (those must stay dynamic). Shared
## by _cull_settled_bodies (runtime) and create_generic_object (reload) so both agree.
func _is_cullable_body(node: Node) -> bool:
	if not is_instance_valid(node) or not (node is RigidBody3D) or node is Vehicle:
		return false
	var parent: Node = node.get_parent()
	return not (parent is Player or parent is Vehicle)

## True when [param body] sits over a planet whose terrain collision has NOT been built under it yet.
## False in open space — there is nothing to wait for — and false once the chunk is resident.
##
## The same question PlayerServer._hold_until_ground asks, through the same PlanetTerrain accessor, so
## a body and a player can never disagree about whether the ground beneath them exists.
func _ground_missing_under(body: Node3D) -> bool:
	if not is_instance_valid(body) or not body.is_inside_tree():
		return false
	var planet: Planet = null
	var node: Node = body
	while node != null:
		if node is Planet:
			planet = node as Planet
			break
		node = node.get_parent()
	if planet == null or planet.planet_terrain == null:
		return false
	return not planet.planet_terrain.has_collision_under(body.global_position)


func _freeze_culled_body(rb: RigidBody3D) -> void:
	rb.linear_velocity = Vector3.ZERO
	rb.angular_velocity = Vector3.ZERO
	rb.freeze = true
	# OCS: drop the body out of Jolt's broadphase entirely. freeze=true alone keeps it registered
	# (residual per-step cost), so we also disable its own collision shapes and stop its script tick.
	rb.set_physics_process(false)
	_set_body_shapes_disabled(rb, true)
	rb.set_meta("_culled_frozen", true)
	rb.remove_meta("_settle_ticks")

func _unfreeze_culled_body(rb: RigidBody3D) -> void:
	# On a spinning planet the physics pose went stale while the body was culled: Planet skips frozen
	# bodies (their shapes are off, so carrying them would be pure cost — and would wake them). Its
	# node transform followed the scene graph, so push that back before the shapes come back on.
	PhysicsServer3D.body_set_state(rb.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM,
			rb.global_transform)
	_set_body_shapes_disabled(rb, false)
	rb.set_physics_process(true)
	rb.freeze = false
	rb.linear_velocity = Vector3.ZERO
	rb.angular_velocity = Vector3.ZERO
	rb.remove_meta("_culled_frozen")
	# Force a replication resend so it re-registers in Horizon/GORC for nearby clients after idling.
	if "server_last_position" in rb:
		rb.server_last_position = Vector3.INF

## Enable/disable the body's OWN collision shapes (direct CollisionShape3D/Polygon children) so it
## leaves/re-enters Jolt's broadphase. Child Area3D shapes (interaction zones) are left untouched.
func _set_body_shapes_disabled(rb: RigidBody3D, disabled: bool) -> void:
	for c in rb.get_children():
		if c is CollisionShape3D:
			(c as CollisionShape3D).disabled = disabled
		elif c is CollisionPolygon3D:
			(c as CollisionPolygon3D).disabled = disabled


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
			# print("[Pin] no planet near body at ", body_pos,
			# 	" (closest planets: ", _debug_closest_planets(body_pos, 3), ")")
		return
	# Planet-LOCAL (body-frame) direction, through the planet's own conversion — the SAME one
	# PlanetTerrain.collision_chunk_key uses to answer "is the ground here loaded?". They must agree on
	# the tile: vec2pix_nest expects the body frame, and the planet spins, so a world-frame direction
	# resolves to the wrong tile and the one actually under the player is never pinned.
	var dir: Vector3 = best_planet.local_dir_of(body_pos)
	if dir.is_zero_approx():
		return
	var pd = best_planet.planet_data
	# Collision detail nside: the client's FINEST LOD nside on crack planets, so
	# the pinned collision is built on the SAME grid the visual renders (see
	# PlanetData.collision_detail_nside); export nside otherwise.
	var nside: int = pd.collision_detail_nside()
	var ipix: int = HEALPix.vec2pix_nest(nside, dir)
	# Pin the chunk under the body. At the fine collision nside (crack planets)
	# each chunk is small (~sub-km), so pin 2 neighbour rings for a walkable
	# margin that streams as the body moves. Coarse export chunks are ~100 km —
	# one already covers the body amply, so no ring there.
	var pin_ipix := {ipix: true}
	if nside > pd.export_nside:
		# BFS outward 2 rings over the HEALPix neighbour graph.
		var frontier: Array = [ipix]
		for _ring in 2:
			var next_frontier: Array = []
			for p in frontier:
				var nbrs := HEALPix.get_neighbors_nest(nside, p)
				for _dn in nbrs:
					var nb: int = nbrs[_dn]
					if nb >= 0 and not pin_ipix.has(nb):
						pin_ipix[nb] = true
						next_frontier.append(nb)
			frontier = next_frontier
	for pi in pin_ipix:
		pins_by_planet[best_uuid]["hp_n%d_p%d" % [nside, pi]] = true
	if _pin_debug_logged < PIN_DEBUG_MAX:
		_pin_debug_logged += 1
		var alt: float = sqrt(best_dist_sq) - best_planet.planet_data.radius
		# print("[Pin] body at ", body_pos, " → planet '", best_planet.name,
		# 	"' alt=", alt, " m  key=", key)


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
	Engine.physics_ticks_per_second = 60
	Engine.max_fps = 60

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
	if players_list.has(message["player_id"]):
		# Input sanity guard: genuine client input (movement/update_velocity,
		# see client.gd _on_client_action_move) is a 2D direction with
		# components in [-1, 1] and NO "z" key. Anything else (a malformed or
		# misrouted message carrying a 3D world position) would be NORMALIZED
		# by the walk code into a full-speed movement command — reject it.
		var pos_data: Dictionary = message["data"]["pos"]
		if pos_data.has("z"):
			return
		var input_x := float(pos_data["x"])
		var input_y := float(pos_data["y"])
		if absf(input_x) > 1.5 or absf(input_y) > 1.5:
			return
		var player = players_list[message["player_id"]]
		player.input_from_server.input_direction = Vector2(input_x, input_y)
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

## A server-authoritative move from a Player (see Player.emit_move). The FRAME is deliberately NOT a
## parameter: it is read from the scene tree HERE, from the very node whose position we just received.
## "The parent Horizon believes in" is therefore a pure function of "the parent in the tree", and the
## two can no longer be separate states that drift apart unnoticed. A caller cannot announce a frame
## it has not actually moved into, because a caller no longer gets to announce anything.
##
## A frame change is a first-class reason to send, exactly like a position change — the same rule
## PropNet.server_tick already applies to props. It used to ride along as an extra field on a
## position packet, so a reparent that happened not to move the body was silently swallowed.
func _on_player_move(client_uuid: String, position: Vector3, rotation: Vector3) -> void:
	var player = players_list.get(client_uuid)
	if not is_instance_valid(player):
		return

	var frame_uuid: String = PropSpawn.parent_frame_uuid(player)
	var last_frame: String = players_list_last_parent.get(client_uuid, "")
	var frame_changed: bool = last_frame != frame_uuid
	var moved: bool = players_list_last_movement.get(client_uuid) != position \
			or players_list_last_rotation.get(client_uuid) != rotation
	if not moved and not frame_changed:
		return

	if frame_changed:
		var parent_name: String = player.get_parent().name if player.get_parent() != null else "<none>"
		print("[Server] player %s frame '%s' -> '%s' (%s)" % [client_uuid, last_frame, frame_uuid, parent_name])
		if frame_uuid == "":
			# The body sits under a node Horizon knows nothing about, so its LOCAL position is about to
			# be published as WORLD coordinates. Harmless while every frame is motionless; a runaway the
			# day frames orbit. Loud on purpose — this is the one divergence deriving cannot prevent.
			push_warning("[Server] player %s is under '%s', which carries no uuid: its position will be sent as world coordinates"
					% [client_uuid, parent_name])
		players_list_last_parent[client_uuid] = frame_uuid

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

	# players_newposition is one entry per player per flush, so a later move in the same window
	# overwrites this one. Carry a frame change already queued onto the newer pose instead of losing
	# it — both poses are expressed in the SAME (new) frame, so this is always safe. The old code
	# returned early here instead, which threw the fresher position away to save the parent.
	if frame_changed:
		prep["parent_id"] = frame_uuid
	elif players_newposition.has(client_uuid) and players_newposition[client_uuid].has("parent_id"):
		prep["parent_id"] = players_newposition[client_uuid]["parent_id"]

	players_list_last_movement[client_uuid] = position
	players_list_last_rotation[client_uuid] = rotation
	if _check_out_of_zone(client_uuid):
		prep["out_of_zone"] = serverinfo_uuid
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
		"event": "update_object",
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
		# Player reconnecting — clean up stale instance and respawn
		prints("Player reconnecting, removing stale instance: %s" % player_uuid)
		var old_player = players_list[player_uuid]
		players_list.erase(player_uuid)
		players_list_last_movement.erase(player_uuid)
		players_list_last_rotation.erase(player_uuid)
		players_list_last_parent.erase(player_uuid)
		players_list_creationdate.erase(player_uuid)
		if is_instance_valid(old_player):
			old_player.queue_free()
		# Clear any stale pending messages for this player
		for msg in pending_messages_player_parenting.duplicate():
			if msg["data"].get("object_uuid", "") == player_uuid:
				pending_messages_player_parenting.erase(msg)
		# Fall through to spawn the new instance

	prints("Creating player on server side: %s" % event)
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

	if player_data.has("is_npc") and player_data["is_npc"] == true:
		spawned_entity_instance.is_npc = true

	var parented = false
	if player_data["parent_id"] != "":
		var parent = _search_parent_node(player_data["parent_id"])
		if parent != null:
			parented = true
			parent.add_child(spawned_entity_instance)

	if not parented:
		# World-frame spawn: Horizon gave us no parent, so this body is a child of the universe root.
		# Its position is world coordinates and it is in NO planet's subtree — it will not be carried
		# when frames start moving (orbit), while the terrain under it will be. Flagged, not fixed:
		# choosing a frame for a parentless player is a design call, not a plumbing one.
		push_warning("[Server] player %s spawned with no networked parent: world frame, will not follow a moving frame"
				% player_uuid)
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
	# Ask for the collision under this player NOW rather than up to PIN_TICK_INTERVAL render frames from
	# now: the body is held still until that chunk lands (PlayerServer._hold_until_ground), so every
	# frame of pinning latency is a frame of frozen player. Idempotent — the sweep pushes the whole set,
	# so calling it early cannot drop another player's pins.
	_refresh_active_body_pins()
	prints("spawning player", player_uuid, "at", spawned_entity_instance.global_position)

	players_list_last_movement[player_uuid] = spawned_entity_instance.global_position
	players_list_last_rotation[player_uuid] = spawned_entity_instance.global_rotation
	# Seed the frame memo with the parent we just attached to: Horizon asked for it, so it already
	# knows. Without this the very first tick would re-announce a frame nobody changed.
	players_list_last_parent[player_uuid] = PropSpawn.parent_frame_uuid(spawned_entity_instance)

	spawned_entity_instance.connect("hs_server_move", _on_player_move)
	spawned_entity_instance.connect("hs_server_player_update", _on_player_update)
	players_list_creationdate[player_uuid] = Time.get_ticks_msec() + 500

func set_serverinfo(uuid: String) -> void:
	serverinfo_uuid = uuid

func create_generic_object(event: Dictionary) -> void:
	# spawn genericprops
	var object_data = event["data"]["object_data"]

	# Idempotency guard: a prop can be requested twice for the SAME uuid — e.g. a designer-placed
	# mining_depot is both echoed from persistence (Horizon) AND self-spawned by its in-scene
	# placeholder with the same deterministic uuid. Creating it twice leaves two overlapping bodies at
	# the same (planet-scale) spot. Never create a uuid we already have.
	var _existing_uuid = event["data"].get("object_uuid", "")
	var _existing_type = event["data"].get("object_type", "")
	if _existing_uuid != "" and props_list.has(_existing_type) \
			and props_list[_existing_type].has(_existing_uuid) \
			and is_instance_valid(props_list[_existing_type][_existing_uuid]):
		push_warning("[Server] create_generic_object: skipping duplicate uuid=%s type=%s (already created)" % [_existing_uuid, _existing_type])
		return

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

	# A persisted prop can reference a scene that no longer exists at that path (e.g. moved or
	# renamed by the asset-taxonomy migration). Skip it instead of crashing the whole loader.
	if prop_scene == null:
		push_warning("create_generic_object: scene not found for scenename '%s' (uuid %s), skipping" \
			% [object_data["scenename"], event["data"]["object_uuid"]])
		return

	var spawnable_prop_instance = prop_scene.instantiate()
	# Address the networking through the PropSync component when the prop has one; fall back to the root
	# for props not yet migrated to the component (so migration is incremental). Body-level ops
	# (physics/freeze/transform/props_list) stay on the root; only the contract (uuid/signals/data) moves.
	var net = PropSync.of(spawnable_prop_instance)
	if net == null:
		net = spawnable_prop_instance
	spawnable_prop_instance.set_physics_process(false)
	net.client_channel_data_update(object_data)
	net.uuid = event["data"]["object_uuid"]
	spawnable_prop_instance.tree_entered.connect(func():
		spawnable_prop_instance.owner = get_tree().current_scene
	)

	if object_data.has("parent_id"):
		if object_data["parent_id"] != "":
			var parent = _search_parent_node(object_data["parent_id"])
			if parent != null:
				parent.add_child(spawnable_prop_instance)
				if parent.has_method("request_nav_rebake"):
					parent.request_nav_rebake()
			else:
				universe_scene.add_child(spawnable_prop_instance)
		else:
			universe_scene.add_child(spawnable_prop_instance)
	else:
		universe_scene.add_child(spawnable_prop_instance)

	if net.has_signal("hs_server_prop_update"):
		net.connect("hs_server_prop_update", _on_prop_update)
	else:
		push_warning("[Server] create_generic_object: scene '%s' root has no signal hs_server_prop_update (type=%s)" \
			% [object_data["scenename"], spawnable_prop_instance.get_class()])
	if net.has_signal("hs_server_prop_delete"):
		net.connect("hs_server_prop_delete", _on_prop_delete)
	else:
		push_warning("[Server] create_generic_object: scene '%s' root has no signal hs_server_prop_delete (type=%s)" \
			% [object_data["scenename"], spawnable_prop_instance.get_class()])
	# Must be after signals in case call signals if modifications done in client_channel_data_update
	net.client_channel_data_update(object_data)

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
		# At server boot there are NO players yet, so every reloaded body would spawn awake and re-run
		# collision for ~SETTLE_TICKS before the settle-culler freezes it — a startup CPU spike with
		# thousands of rocks. Freeze settled free bodies up front instead; the culler unfreezes them
		# (they carry the _culled_frozen flag) as soon as a player comes within ACTIVE_RADIUS. A body
		# already near a player (rare at boot, possible on later GORC streaming) stays awake.
		if _is_cullable_body(spawnable_prop_instance) and not _player_within(pos, ACTIVE_RADIUS):
			_freeze_culled_body(spawnable_prop_instance)
		elif spawnable_prop_instance is RigidBody3D and _ground_missing_under(spawnable_prop_instance):
			# Nothing under it YET. Terrain collision is built chunk by chunk on worker threads, and at
			# a cold start `user://prebaked_collision/` is empty, so a body created now would meet only
			# the safety shells 100-200 m below the playable surface and sink through them.
			#
			# This branch exists because the one above deliberately skips VEHICLES: a truck being
			# driven must never be frozen. But a truck being CREATED is driven by nobody, and sixteen
			# trucks seeded into the world fell 7.4 km — measured, ending 1.8 km under the reference
			# radius, far outside every player's replication range, which is why none of them ever
			# appeared. Rocks were spared only because the branch above already froze them.
			#
			# ⚠️ Freezing a VehicleBody3D stops its suspension and lets the wheels sink into the body
			# (see the parking work). Harmless here and only here, because the hold is transient: the
			# culler unfreezes on approach, by which time the player is standing on loaded terrain, and
			# the suspension pushes the vehicle back up on the first step.
			_freeze_culled_body(spawnable_prop_instance)
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
		var net = PropSync.of(object)
		if net == null:
			net = object
		net.client_channel_data_update(event["data"]["object_data"])


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
	# Unified object-property replication: a player is sent as one prop-style entry
	# {type, uuid, <properties>} on the shared "props/update_object" channel, exactly
	# like a generic prop update. Horizon merges the whitelisted properties and
	# broadcasts them to nearby clients.
	var entry := {
		"type": "player",
		"uuid": client_uuid,
	}
	for key in properties.keys():
		entry[key] = properties[key]
	var message = {
		"namespace": "props",
		"event": "update_object",
		"data": [entry]
	}
	# TEMP DEBUG (dialog): prove whether the line reaches the websocket, i.e. whether the gap is
	# server-side or Horizon-side. Remove once the conversation replication is settled.
	if entry.has("conversation"):
		print("[dialog] -> wire: ", JSON.stringify(message))
	ServerNetwork.send_message(message, "player_update")

func remove_player(event: Dictionary) -> void:
	var player_uuid = event["data"]["object_uuid"]
	# Self-healing backstop: if this (PNJ) player owned a depot's reception role, free it so the
	# role never stays stuck on a gone owner. The depots register in the "cargo_depots" group.
	for depot in get_tree().get_nodes_in_group("cargo_depots"):
		if depot.has_method("clear_reception_owner_if"):
			depot.clear_reception_owner_if(player_uuid)
	if players_list.has(player_uuid):
		var player = players_list[player_uuid]
		print("player has quit the game: %s" % player_uuid)
		players_list.erase(player_uuid)
		player.queue_free()
	# Clear any pending spawn messages for this player
	for msg in pending_messages_player_parenting.duplicate():
		if msg["data"].get("object_uuid", "") == player_uuid:
			pending_messages_player_parenting.erase(msg)

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
	# Fine-collision planets (file-mode crack planets like tarsis_4) get ALL
	# their collision from the per-body pin system at collision_detail_nside
	# (n8192). Do NOT also blanket the zone with coarse export-nside (n64)
	# chunks: both attach shapes to the SAME PlanetCollision body, and where a
	# coarse ~100 km facet crosses the fine surface the two floors sit within
	# capsule height — a body lands on the lower floor and is silently
	# depenetrated out of the upper one a few ticks later, forever. That was
	# the player/vehicle "dancing" around the base, and why the vehicle could
	# never fall asleep. An empty desired set also unloads any coarse chunks
	# attached earlier (pins are preserved — see _apply_residency).
	if planet.planet_data.collision_detail_nside() > planet.planet_data.export_nside:
		planet.planet_terrain.set_resident_chunks(PackedStringArray())
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
