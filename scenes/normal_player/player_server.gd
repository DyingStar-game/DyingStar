class_name PlayerServer
extends Node

## Server-authoritative logic for a player — runs ONLY on the dedicated game server. Owns (over the
## migration) the physics tick, input application, carry / line-of-sight, doors, spawns and the
## server_action_received dispatcher. Created by Player as a child node; it reaches the shared body,
## nodes and state through `player`. Helpers still on the Player facade are called via `player.` until
## they migrate too. (Filled in incrementally.)

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")
## Kept in sync with Player.JUMP — a `match` pattern needs a compile-time constant, so we can't read
## `player.JUMP` here.
const JUMP: String = "jump"

## The body / facade this role drives (a Player). Untyped ON PURPOSE: typing it `Player` would create a
## cyclic class_name dependency (Player references PlayerServer/PlayerClient, which reference Player) and
## break global script compilation. Untyped duck-typing still reaches every Player member.
var player

## One-time init, called by Player._ready() once `player` is wired and both are in the tree.
func setup() -> void:
	pass

## Authoritative dispatcher for a client action, called by the network layer through Player (only the
## dedicated server ever receives it). Every branch reads/writes the shared body via `player`.
func server_action_received(data: Dictionary) -> void:
	match data["action"]:
		JUMP:
			player.is_jumping = true
		"toggle_flashlight":
			# Server-authoritative: flip the state and replicate it so the owner AND other players
			# see the torch (replicated as a state, not the action — a missed event can't desync it).
			player.flashlight.visible = not player.flashlight.visible
			player.server_send_properties_to_client({"flashlight": player.flashlight.visible})
		"screen_state":
			# A 3D screen (mining depot) button was pressed: route it to that screen.
			if player.screen_interacting and player.screen_interacting.has_method("update_screen"):
				player.screen_interacting.update_screen(data)
		"update_property":
			# Generic player-property update (tech-debt A): apply the authoritative side-effects we
			# know about, then replicate every property to nearby clients.
			var props: Dictionary = data.duplicate()
			props.erase("action")
			if props.has("tools"):
				player.mining_tool.server_set_tool(str(props["tools"]))
			if props.has("head"):
				# Apply on the server too so the interaction ray + carried item follow the gaze
				# (planet only; in 0g the body orientation is used instead).
				player.camera_pivot.rotation.x = float(props["head"])
			player.server_send_properties_to_client(props)
		"perforate_rock":
			# Authoritative fracture: cut the targeted rock along the aimed fault.
			var rock = _find_mining_rock(str(data.get("uuid", "")))
			if rock and rock.has_method("server_perforate"):
				var h: Dictionary = data.get("hit", {})
				var dd: Dictionary = data.get("dir", {})
				rock.server_perforate(
					Vector3(h.get("x", 0.0), h.get("y", 0.0), h.get("z", 0.0)),
					Vector3(dd.get("x", 0.0), dd.get("y", 0.0), dd.get("z", 0.0)))
		"delete_prop":
			# Admin cleanup tool: permanently remove a player-spawned prop.
			var del_type: String = str(data.get("type", ""))
			var del_uuid: String = str(data.get("uuid", ""))
			if del_uuid == "" or not (del_type in ["miningrock", "box", "mining_depot", "palette_container", "vehicle"]):
				print("🗑️ Admin delete refused: type=%s uuid=%s" % [del_type, del_uuid])
			elif NetworkOrchestrator.protected_prop_uuids.has(del_uuid):
				# World infrastructure placed by designers (e.g. a depot in the city): keep it.
				print("🗑️ Admin delete refused: %s is protected world infrastructure" % del_uuid)
			else:
				# Free the node (removes its collision body) AND tell Horizon to drop it from the GORC +
				# database. Both are needed: queue_free alone may not replicate the delete, and the GORC
				# delete alone leaves a collision ghost.
				var prop = _find_deletable_prop(del_uuid)
				if prop != null and is_instance_valid(prop):
					print("🗑️ Admin delete: freeing local node %s %s" % [del_type, del_uuid])
					_reparent_children_of_prop(prop)
					prop.queue_free()
				if NetworkOrchestrator.network_agent.has_method("_on_prop_delete"):
					# Not held locally (e.g. loaded from the database): tell Horizon directly.
					print("🗑️ Admin delete: forwarding to Horizon %s %s" % [del_type, del_uuid])
					NetworkOrchestrator.network_agent._on_prop_delete(del_uuid, del_type)
		"spawn_vehicle":
			# Server-authoritative vehicle: spawn it in Horizon (all clients) AND locally on this game
			# server (physics body that simulates + replicates). B1 networking.
			var v_pos: Dictionary = data.get("position", {})
			NetworkOrchestrator.spawn_prop_authoritative({
				"type": "vehicle",
				"uuid": UUID_UTIL.v4(),
				"position": {
					"x": float(v_pos.get("x", 0.0)),
					"y": float(v_pos.get("y", 0.0)),
					"z": float(v_pos.get("z", 0.0))
				},
				"rotation": {"x": 0.0, "y": 0.0, "z": 0.0},
				"scenename": "scenes/vehicles/trucks/truck.tscn",
				"parent_id": str(data.get("parent_id", "")),
			})
		"enter_vehicle":
			var veh = _find_vehicle(str(data.get("target_uuid", "")))
			if veh != null and veh.has_method("server_enter"):
				veh.server_enter(player, str(data.get("seat", "")))
		"exit_vehicle":
			var veh_out = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_out != null and veh_out.has_method("server_exit"):
				veh_out.server_exit(player)
		"vehicle_input":
			var veh_in = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_in != null and veh_in._pilot == player and veh_in.has_method("set_drive_input"):
				veh_in.set_drive_input(
					float(data.get("throttle", 0.0)),
					float(data.get("steer", 0.0)),
					bool(data.get("brake", false)))
		"reset_vehicle":
			var veh_r = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_r != null and veh_r._pilot == player and veh_r.has_method("reset_upright"):
				veh_r.reset_upright()
		"vehicle_handbrake":
			var veh_h = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_h != null and veh_h._pilot == player and veh_h.has_method("toggle_handbrake"):
				veh_h.toggle_handbrake()
		"vehicle_lights":
			var veh_l = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_l != null and veh_l._pilot == player and veh_l.has_method("toggle_headlights"):
				veh_l.toggle_headlights()
		"vehicle_door":
			# A door handle is operated on foot by anyone nearby - NOT gated on the driver. Server-
			# authoritative: (1) the box it aimed at must match the player's side (outdoor on foot, indoor
			# when seated in this vehicle), and (2) that box must have a clear sightline (see _can_see).
			var veh_d = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_d != null and veh_d.has_method("server_toggle_door"):
				var handle_d: Node3D = veh_d.get_door_handle(str(data.get("door_id", ""))) \
						if veh_d.has_method("get_door_handle") else null
				var inside_d: bool = veh_d.has_method("is_occupied_by") and veh_d.is_occupied_by(player)
				var claimed_side: String = str(data.get("side", ""))
				var side_ok: bool = claimed_side == "" or claimed_side == ("indoor" if inside_d else "outdoor")
				if side_ok and (handle_d == null or player._can_see(handle_d)):
					veh_d.server_toggle_door(str(data.get("door_id", "")))
		"action":
			print("action key pressed by player")
			if player.hands_item != null:
				# we have something in hands, so release it
				print("player has an item in hands, dropping it")
				# Generic: let the object know it is no longer carried (issue #124).
				if player.hands_item.has_method("set_carried"):
					player.hands_item.set_carried(false)
				player.hands_item.remove_collision_exception_with(player)  # it can collide with us again
				_carry_ignore_vehicles(player.hands_item, false)  # restore collision with vehicles
				# Drop INTO a bed -> load it onto that truck. We load it if we stand in the bed, OR if we
				# drop it from outside but it lands inside a nearby truck's cargo bay.
				if player.hands_item is RigidBody3D:
					var bed = player._cargo_bed_for_drop(player.hands_item.global_position)
					if bed != null:
						bed.lock_dropped_cargo(player.hands_item)
						player.hands_item = null
						player.server_send_properties_to_client({"carrying": false})
						return
				var drop_parent = player.get_parent()
				player.hands_item.server_parent_change(drop_parent)
				player.hands_item.freeze = false
				# Robust to the scene layout: a parent without a uuid (grouping/test-zone node) = "".
				player.hands_item.send_properties_to_client(str(drop_parent.uuid) if "uuid" in drop_parent else "")
				player.hands_item = null
				# Stop carrying on all clients (perforator comes back) (issue #124).
				player.server_send_properties_to_client({"carrying": false})
			else:
				# Pick up the carriable the CLIENT aimed at: it sends the uuid under its crosshair, so we
				# grab exactly that one (our own server ray can be a hair off — pitch is throttled). (#124)
				var parent_node = _find_carriable(str(data.get("target_uuid", "")))
				var picked_up := false
				# Server-authoritative: same gate as the client — grabbable (not already carried) AND a
				# clear line of sight, so a thin wall can't be exploited to grab through it.
				var can_grab: bool = parent_node != null and parent_node.has_method("interact") \
						and parent_node.interact(player) and not player._is_blocked_by_geometry(parent_node)
				if can_grab:
					# If it's secured in a vehicle bed, take it out of the load first (retrieval).
					var prev_parent = parent_node.get_parent()
					if prev_parent.has_method("release_cargo"):
						prev_parent.release_cargo(parent_node)
					parent_node.freeze = true
					parent_node.add_collision_exception_with(player)  # solid to others, not the carrier
					_carry_ignore_vehicles(parent_node, true)  # a held (frozen) crate must not shove a truck
					# Make sure its replication is active: a crate that sat in a bed may have had its
					# _physics_process paused, which would stop PropNet from replicating a later drop.
					parent_node.set_physics_process(true)
					parent_node.server_parent_change(player)
					parent_node.position = Vector3(0.0, 1.0, -1.0)
					#  send reparent to client
					parent_node.send_properties_to_client(player.client_uuid)
					player.hands_item = parent_node
					picked_up = true
					# Generic: mark carriables (e.g. a fault-less ore) as taken so nobody else can grab
					# them while in hands (issue #124).
					if parent_node.has_method("set_carried"):
						parent_node.set_carried(true)
					# Mark as carrying on all clients (perforator stows) (issue #124).
					player.server_send_properties_to_client({"carrying": true})
				if not picked_up:
					# Grabbed nothing: tell the owner to undo its optimistic stow (issue #124).
					player.server_send_properties_to_client({"carrying": false})

## Find a spawned mining rock by its uuid (server-side).
## Walk up from a raycast hit to the vehicle node it belongs to (group "vehicle"), else null.
func _find_vehicle(target_uuid: String) -> Node:
	if target_uuid == "":
		return null
	for v in get_tree().get_nodes_in_group("vehicle"):
		if "uuid" in v and str(v.uuid) == target_uuid:
			return v
	return null

func _find_mining_rock(rock_uuid: String) -> Node:
	if rock_uuid == "":
		return null
	for r in get_tree().get_nodes_in_group("miningrock"):
		if "uuid" in r and str(r.uuid) == rock_uuid:
			return r
	return null

## Find a player-spawned prop by uuid for the admin cleanup tool (server-side). Looks in the
## prop registry (any type) first, then the "carriable" group (rocks/boxes), so it works
## regardless of how the prop was registered.
func _find_deletable_prop(target_uuid: String) -> Node:
	if target_uuid == "":
		return null
	for ptype in NetworkOrchestrator.props_list.keys():
		if NetworkOrchestrator.props_list[ptype].has(target_uuid):
			var n = NetworkOrchestrator.props_list[ptype][target_uuid]
			if is_instance_valid(n):
				return n
	for n in get_tree().get_nodes_in_group("carriable"):
		if "uuid" in n and str(n.uuid) == target_uuid:
			return n
	# Fallback: scan the tree for ANY node carrying this uuid (depots / persisted props that
	# aren't in props_list nor the carriable group). The node has a collision body, so it IS
	# in the tree -> we find it and can free it (otherwise its collision lingers as a ghost).
	return _find_node_by_uuid(get_tree().get_root(), target_uuid)

## Recursive search for a node whose `uuid` matches (server-side helper).
func _find_node_by_uuid(node: Node, target_uuid: String) -> Node:
	if "uuid" in node and str(node.uuid) == target_uuid:
		return node
	for child in node.get_children():
		var found: Node = _find_node_by_uuid(child, target_uuid)
		if found != null:
			return found
	return null

## Find a carriable (group "carriable") by its uuid (server-side). Used to pick up
## exactly the object the client aimed at. (#124)
func _find_carriable(target_uuid: String) -> Node:
	if target_uuid == "":
		return null
	for n in get_tree().get_nodes_in_group("carriable"):
		if "uuid" in n and str(n.uuid) == target_uuid:
			return n
	return null

## Make a carried prop pass through (or collide again with) every vehicle. A carried prop is
## frozen, which the physics solver treats as immovable / infinite mass — letting it touch a
## vehicle would shove or flip the (much heavier) truck, bypassing its real mass. So while it is
## held it ignores vehicles; cargo is loaded by DROPPING it into the bed, not by ramming.
func _carry_ignore_vehicles(prop: Node, ignore: bool) -> void:
	if prop == null:
		return
	for v in get_tree().get_nodes_in_group("vehicle"):
		if v is CollisionObject3D and v != prop:
			if ignore:
				prop.add_collision_exception_with(v)
			else:
				prop.remove_collision_exception_with(v)

func _reparent_children_of_prop(prop: Node) -> void:
	if prop == null or not is_instance_valid(prop):
		return
	var parent = prop.get_parent()
	for child in prop.get_children():
		if is_instance_valid(child):
			if child.has_method("client_parent_change"):
				child.server_parent_change(parent)
			elif child.has_method("_safe_reparent_and_sync"):
				child._safe_reparent_and_sync(parent)
			else:
				print("WARNING: child %s of prop %s has no client_parent_change method" % [child.name, prop.name])
