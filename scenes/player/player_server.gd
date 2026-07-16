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
## Physics-held carry: cap on the follow velocity (m/s) so a fast turn can't tunnel a carried body
## through a thin wall (paired with continuous_cd while held).
const _CARRY_FOLLOW_MAX_SPEED := 25.0
## Physics-held carry: max height (m) the camera pitch raises/lowers the hold spot, up and down.
const _CARRY_PITCH_LIFT := 2.0
## How much faster than the gaze the object rises with pitch (>1 = it climbs above the crosshair on a
## modest up-look, so you see under it to place it on a high shelf without craning your neck). Saturates
## at _CARRY_PITCH_LIFT.
const _CARRY_PITCH_GAIN := 3.0
## Distance (m) to the hold spot under which a freshly-picked object counts as "in hand": its collision,
## suppressed during the travel so nothing interferes, is restored at that point.
const _CARRY_INHAND_DIST := 0.3
## Keep the hold spot at least this far (m) above any solid surface below it, so looking down (e.g. to
## aim at an object on the ground) can't drive the carried body underground.
const _CARRY_GROUND_CLEARANCE := 0.2
## Keep the hold spot at least this far (m) below a ceiling above it, so looking up inside a container /
## building can't push the carried body up through the roof.
const _CARRY_CEILING_CLEARANCE := 0.35
## Rotation damping applied to a carried body: it stays dynamic-rotation (a knock nudges its
## orientation — the object reacts to bumps) but the spin bleeds off quickly instead of tumbling.
const _CARRY_ANGULAR_DAMP := 4.0
## Yaw applied to a carried object per mouse-wheel notch (radians) — see the "carry_rotate" action.
const CARRY_ROTATE_STEP := deg_to_rad(15.0)
## Free-rotate gain: radians of object rotation per unit of streamed mouse motion. The client streams
## the same scaled motion it uses for the camera (event.relative * 0.001), so this is tuned so a
## screen-width drag is roughly a full turn — see the "carry_free_rotate" action.
const CARRY_FREE_ROTATE_GAIN := 6.0
## Dev spawn wheel: how far above / below the aimed point we look for the ground (m). Generous enough
## for a slope or a step in front of us, short enough that a miss means "there really is nothing here".
const GROUND_SEARCH := 30.0

## The body / facade this role drives (a Player). Untyped ON PURPOSE: typing it `Player` would create a
## cyclic class_name dependency (Player references PlayerServer/PlayerClient, which reference Player) and
## break global script compilation. Untyped duck-typing still reaches every Player member.
var player

## Server-only: consecutive quasi-still ticks, used to throttle move_and_slide for idle players.
var _idle_settled_ticks: int = 0

## Jumps performed by this player, replicated with the jump event so each one is a NEW value (see the
## jump in _physics_process): an identical repeated value would be swallowed by delta compression.
var _jump_count: int = 0
## Dev spawn wheel: catalogue keys asked for since the last physics tick (see _spawn_from_catalog).
var _spawn_queue: Array[String] = []
## Server-only line-of-sight ray (lazy) + carry-prompt throttle timer.
var _los_ray: RayCast3D = null
var _carry_prompt_timer: float = 0.0

## One-time spawn init, called by Player._ready() once `player` is wired and both are in the tree.
## Server placement: sit the body at its spawn position and start monitoring detection zones.
## (This is the former dedicated-server branch of Player._ready.)
func setup() -> void:
	player.position = player.spawn_position
	player.connect_area_detect()
	player.update_last_basis()

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
		"spawn_prop":
			# Dev spawn wheel (key T): the client only NAMES what it wants; we own everything else.
			_spawn_from_catalog(str(data.get("key", "")))
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
		"carry_rotate":
			# Spin the carried object around the vertical by one notch, about its geometry CENTER. The item
			# holds its orientation on its own (angular axes locked, angular_velocity zeroed in
			# _server_update_carried_item), so a one-off rotation here sticks. Around up_direction so it
			# stays upright on a planet.
			var step: float = CARRY_ROTATE_STEP * signf(float(data.get("dir", 1)))
			_rotate_held_about_center(Basis(player.up_direction.normalized(), step))
		"carry_free_rotate":
			# Hold the middle mouse button and move the mouse to tumble the carried object on all axes,
			# about its geometry CENTER (so it spins in place, not orbits its off-center body origin). In
			# addition to the wheel's single-axis notch. Yaw about the gravity up from mouse X; pitch about
			# the camera's horizontal right axis from mouse Y, so a drag maps to what the player sees.
			var dxr: float = float(data.get("dx", 0.0)) * CARRY_FREE_ROTATE_GAIN
			var dyr: float = float(data.get("dy", 0.0)) * CARRY_FREE_ROTATE_GAIN
			var pitch_axis: Vector3 = player.camera_pivot.global_basis.x.normalized()
			_rotate_held_about_center(Basis(player.up_direction.normalized(), dxr) * Basis(pitch_axis, dyr))
		"vehicle_ignition":
			var veh_i = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_i != null and veh_i._pilot == player and veh_i.has_method("toggle_engine"):
				veh_i.toggle_engine()  # refused by the vehicle itself if it is still rolling
		"vehicle_horn":
			var veh_n = _find_vehicle(str(data.get("target_uuid", "")))
			if veh_n != null and veh_n._pilot == player and veh_n.has_method("set_horn"):
				veh_n.set_horn(bool(data.get("pressed", false)), bool(data.get("special", false)))
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
				if side_ok and (handle_d == null or _can_see(handle_d)):
					veh_d.server_toggle_door(str(data.get("door_id", "")))
		"action":
			print("action key pressed by player")
			if player.hands_item != null:
				# We have something in hands: release it (drop / bed-load). Shared with the auto-drop.
				_server_drop_carried_item()
			else:
				# Pick up the carriable the CLIENT aimed at: it sends the uuid under its crosshair, so we
				# grab exactly that one (our own server ray can be a hair off — pitch is throttled). (#124)
				var parent_node = _find_carriable(str(data.get("target_uuid", "")))
				var picked_up := false
				# Server-authoritative: same gate as the client — grabbable (not already carried) AND a
				# clear line of sight, so a thin wall can't be exploited to grab through it.
				var can_grab: bool = parent_node != null and parent_node.has_method("interact") \
						and parent_node.interact(player) and not _is_blocked_by_geometry(parent_node)
				if can_grab:
					# If it's secured in a vehicle bed, take it out of the load first (retrieval).
					var prev_parent = parent_node.get_parent()
					if prev_parent.has_method("release_cargo"):
						prev_parent.release_cargo(parent_node)
					# Carry it as a real DYNAMIC body so the physics engine owns its position: it then collides
					# NATURALLY with the ground, walls and vehicles (blocked by them) and pushes lighter props —
					# no manual clamping. Gravity is off + no sleeping while held; the carrier is excepted so it
					# never blocks us. We steer it toward the hold point by velocity each tick (see
					# _server_update_carried_item). Save the gravity scale to restore it on drop.
					parent_node.set_meta("pre_carry_gravity_scale", parent_node.gravity_scale)
					parent_node.freeze = false
					parent_node.gravity_scale = 0.0
					parent_node.can_sleep = false
					parent_node.continuous_cd = true  # follow speed can be high → avoid tunnelling thin walls
					parent_node.add_collision_exception_with(player)  # solid to the world, not the carrier
					# Keep it dynamic-rotation so it REACTS to bumps (a knock against a wall/prop nudges its
					# orientation), but damp the spin heavily so it settles instead of tumbling. Manual
					# orientation (wheel / middle-click) still writes the basis directly. Restored on drop.
					parent_node.set_meta("pre_carry_angular_damp", parent_node.angular_damp)
					parent_node.angular_damp = _CARRY_ANGULAR_DAMP
					# Suppress collisions during the travel to the hand (restored once in hand, see
					# _server_update_carried_item / _CARRY_INHAND_DIST).
					parent_node.set_meta("pre_carry_layer", parent_node.collision_layer)
					parent_node.set_meta("pre_carry_mask", parent_node.collision_mask)
					parent_node.collision_layer = 0
					parent_node.collision_mask = 0
					# Make sure its replication is active: a crate that sat in a bed may have had its
					# _physics_process paused, which would stop PropNet from replicating a later drop.
					parent_node.set_physics_process(true)
					parent_node.server_parent_change(player)
					# NOTE: no snap to a fixed spot in front — with the physics velocity-follow that snap made
					# the crate "teleport" up 1 m on E before easing back down. Left where it was grabbed, it
					# now rises smoothly from there into the hand.
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

# ------------------------------------------------------------------------------
# Dev spawn wheel (key T) — SERVER-AUTHORITATIVE. The client only sends a catalogue key; the scene,
# the object type, the celestial frame and the placement are all decided here.
# ------------------------------------------------------------------------------
## A wheel key arrived. Validate it against the catalogue and QUEUE it: placing a prop needs a ground
## raycast, and the physics space can only be queried during the physics step (this runs on a network
## message, outside it). _flush_spawn_queue does the work on the next tick.
func _spawn_from_catalog(key: String) -> void:
	if SpawnCatalog.entry(key).is_empty():
		print("🌱 Spawn refused: unknown catalogue key '%s'" % key)  # a tampered / stale client
		return
	_spawn_queue.append(key)

## Spawn everything the wheel asked for since the last tick (we are inside the physics step here).
func _flush_spawn_queue() -> void:
	while not _spawn_queue.is_empty():
		_spawn_prop(_spawn_queue.pop_front())

## Place ONE catalogue prop in front of the player and hand it to the network.
##
## The whole placement is computed in WORLD space (global_position, global_basis, up_direction — the
## server's own vectors) and converted to the parent's frame ONCE, at the end. Mixing a LOCAL position
## with WORLD axes — what the old client-side code did — silently skews the result as soon as the
## parent frame is rotated, which the planet/city always is.
func _spawn_prop(key: String) -> void:
	var entry: Dictionary = SpawnCatalog.entry(key)
	if entry.is_empty():
		return
	var forward: Vector3 = -player.global_basis.z  # where the player faces, in world space
	var aim: Vector3 = player.global_position + forward * float(entry["distance"])
	var spawn_world: Vector3 = aim
	var basis: Basis = player.global_basis
	# On a planet: drop the prop ON the ground, standing up along the local vertical. In zero g there
	# is no ground and no vertical: leave it floating in front of the eyes, facing as we do.
	var gravity_area: Node3D = player.get_current_gravity_parent()
	if gravity_area != null:
		var up: Vector3 = player.up_direction
		var ignore: Array[RID] = [player.get_rid()]  # don't let our own body catch the ray
		var ground: Variant = PropSpawn.ground_point(
				player.get_world_3d().direct_space_state, aim, up, GROUND_SEARCH, ignore)
		if ground != null:
			spawn_world = (ground as Vector3) + up * float(entry["origin_height"])
		else:
			# Nothing under the crosshair (a hole, a cliff edge): keep the prop at our own height
			# rather than dropping it into the void.
			spawn_world = aim + up * float(entry["origin_height"])
		basis = Globals.align_with_y(Transform3D(player.global_basis, Vector3.ZERO), up).basis
	# Express the placement in the frame of the planet/city we stand on: a prop left in world
	# coordinates is pinned in space while its planet moves away at ~3e10 (it drifts out of sight).
	var net_parent: Node = PropSpawn.find_net_parent(player)
	var local_pos: Vector3 = PropSpawn.to_parent_local(net_parent, spawn_world)
	var local_rot: Vector3 = _to_parent_rotation(net_parent, basis)
	NetworkOrchestrator.spawn_prop_authoritative({
		"type": str(entry["type"]),
		"uuid": UUID_UTIL.v4(),
		"position": {"x": local_pos.x, "y": local_pos.y, "z": local_pos.z},
		"rotation": {"x": local_rot.x, "y": local_rot.y, "z": local_rot.z},
		"scenename": str(entry["scene"]).trim_prefix("res://"),
		"parent_id": PropSpawn.net_parent_uuid(net_parent),
	})
	print("🌱 Spawn '%s' (%s) for %s" % [key, entry["type"], player.client_uuid])

## A WORLD orientation expressed in the parent's frame, as the euler angles the network carries.
func _to_parent_rotation(net_parent: Node, world_basis: Basis) -> Vector3:
	if net_parent is Node3D:
		var parent_basis: Basis = (net_parent as Node3D).global_basis
		return (parent_basis.inverse() * world_basis).orthonormalized().get_euler()
	return world_basis.orthonormalized().get_euler()

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


## Server physics tick — applies replicated input, gravity, carry float + throttled carry prompt, then
## replicates the position. Runs on THIS role's own child node, so the engine calls it only on the
## dedicated server. Reads/writes the shared body through `player`; carry/LOS helpers still live on the
## Player facade for now (2d) and are reached via `player.`.
func _physics_process(delta: float) -> void:
	_flush_spawn_queue()  # the wheel's spawns wait for the physics step: they need a ground raycast
	_server_update_carried_item(delta)
	_server_update_carry_prompt(delta)
	if player.piloting and is_instance_valid(player._seat_node):
		# Seated in a vehicle: ride its seat. Server-authoritative; the emitted position replicates so
		# the player follows the vehicle (camera rides too).
		player._ride_seat(player._seat_node)
		player.new_input_from_server = false
		var seat_p: Vector3 = snapped(player.position, Vector3(0.001, 0.001, 0.001))
		var seat_r: Vector3 = snapped(player.global_rotation, Vector3(0.0001, 0.0001, 0.0001))
		player.emit_signal("hs_server_move", player.client_uuid, seat_p, seat_r, null, player.is_parented)
		return
	if player.new_input_from_server:
		player.input_direction = player.input_from_server["input_direction"]
		player.global_rotation = player.input_from_server["rotation"]
		if player.piloting:
			player.input_direction = Vector2.ZERO  # seated in a vehicle: no walking

	# Server-side "sleep" for settled players: once quasi-still for ~0.5 s, run the full move_and_slide
	# only every 10th tick (6 Hz keeps the floor contact honest). Any input/velocity resets the counter.
	if not player.new_input_from_server and player.input_direction == Vector2.ZERO \
			and player.is_on_floor() and player.velocity.length_squared() < 0.0001:
		_idle_settled_ticks += 1
		if _idle_settled_ticks > 30 and (_idle_settled_ticks % 10) != 0:
			return
	else:
		_idle_settled_ticks = 0

	var sprint = null
	var parent_gravity_area: Area3D = player.gravity_parents.back() if not player.gravity_parents.is_empty() else null

	if parent_gravity_area:
		if parent_gravity_area.gravity_point:
			player.up_direction = parent_gravity_area.global_position.direction_to(player.global_position)
		else:
			player.up_direction = parent_gravity_area.global_basis.y
		player.gravity = player._compute_gravity(parent_gravity_area)
		player.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	else:
		# 0g movement
		player.gravity = 0.0
		player.camera_pivot.rotation.x = 0
		player.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
		var dir = Vector3(player.input_direction.x, 0, player.input_direction.y)
		player.player_thruster_force = 10
		player.velocity += player.global_basis * dir * player.player_thruster_force * delta
		player.velocity *= 0.98

	var move_direction = (player.global_transform.basis * Vector3(player.input_direction.x, 0, player.input_direction.y)).normalized()

	var speed = player.sprint_speed if sprint else player.walk_speed
	if player.mining_tool.is_aiming:
		speed *= player.mining_tool.aim_speed_factor  # slowed down in aim mode
	if player.mining_tool.is_perforating:
		speed = 0.0  # frozen during perforation
	if player.hands_item != null:
		speed *= player.carry_speed_factor  # carrying an ore slows you down (issue #124)

	if player.is_on_floor():
		if player.input_direction:
			player.velocity = move_direction * speed
		else:
			player.velocity = player.velocity.move_toward(Vector3.ZERO, speed)
	else:
		# "air" movement
		if player.input_direction:
			player.velocity += move_direction * speed * delta

	if player.is_on_floor() and player.is_jumping:
		player.velocity += player.up_direction * player.jump_height * player.gravity
		player.is_jumping = false
		# Tell the clients the jump actually HAPPENED (a request while airborne is ignored above, and
		# would otherwise still be heard). They play the jump sound on it — ours and the other players'.
		# The counter is what makes it an EVENT: "action" is a replicated state, delta-compressed, so
		# sending the same "jump" twice in a row would be dropped as "unchanged" and the second jump
		# would be silent. A value that always changes always gets through.
		_jump_count += 1
		player.server_send_properties_to_client({"action": "%s:%d" % [JUMP, _jump_count]})
	# Add gravity ALWAYS (even on the floor) so the capsule stays pressed onto the terrain trimesh and
	# is_on_floor() stays true — gating it on "not is_on_floor()" caused a ~1 cm idle "dancing".
	else:
		player.velocity -= player.up_direction * player.gravity * 2.0 * delta
		player.is_jumping = false

	# Cap fall speed to avoid tunneling through the thin trimesh terrain (move_and_slide has no CCD).
	var _terminal_velocity: float = 60.0
	if player.velocity.length() > _terminal_velocity:
		player.velocity = player.velocity.normalized() * _terminal_velocity

	player.move_and_slide()

	# Safety net: catch a fast fall that tunneled clearly below the planet surface.
	if parent_gravity_area and parent_gravity_area.gravity_point \
			and parent_gravity_area.name == "PlanetGravity":
		_catch_if_below_surface(parent_gravity_area)

	player.update_last_basis()
	player.new_input_from_server = false

	player.emit_signal(
		"hs_server_move",
		player.client_uuid,
		snapped(player.position, Vector3(0.001, 0.001, 0.001)),
		snapped(player.global_rotation, Vector3(0.0001, 0.0001, 0.0001)),
		null,
		player.is_parented
	)

## Primitive: true if a MASK_OBSTACLE ray from the eye to `target` (a world point) is cut by a solid
## before reaching it. `exceptions` are solids to ignore besides ourselves. Used for look-at boxes that
## sit in open air (door handles): the box on the near side is clear, the one behind the body is not.
func _line_of_sight_blocked(target: Vector3, exceptions: Array) -> bool:
	_ensure_los_ray()
	# top_level → target_position is a world-space delta (no parent transform to fight).
	_los_ray.global_position = player.interact_ray.global_position
	_los_ray.target_position = target - _los_ray.global_position
	_los_ray.clear_exceptions()
	_los_ray.add_exception(player)
	for node in exceptions:
		if node is CollisionObject3D:
			_los_ray.add_exception(node)
	_los_ray.force_raycast_update()
	if not _los_ray.is_colliding():
		return false
	# Float32 precision at astronomic world coordinates (the same limit behind the Jolt "dancing" bug)
	# makes the PHYSICS raycast origin imprecise by tens of metres this far out, so it can report a body
	# well off the true eye->box segment as a hit and lock a door that is actually clear. Validate in
	# DOUBLE precision: a real obstruction sits BETWEEN the eye and the door box, so ignore any collider
	# whose accurate position is farther from the eye than the box itself (+ a small size margin).
	var c: Object = _los_ray.get_collider()
	if c is Node3D:
		var box_dist: float = _los_ray.global_position.distance_to(target)
		var hit_dist: float = _los_ray.global_position.distance_to(_los_hit_world_pos(c))
		if hit_dist > box_dist + 2.0:
			return false
	return true

## Server-authoritative "can I actually SEE it?" gate, shared by EVERY look-at interaction (carry AND
## door handles): nothing solid may stand in front of the target. MUST run on the server — the client
## has no collisions, so its answer would always be "clear" and be trivially cheatable.
func _can_see(target: Node) -> bool:
	if not (target is Node3D):
		return false
	# Door handle: pick the box for the side the player is on — seated in this vehicle → indoor box,
	# on foot → outdoor box — then require a clear sightline to it. The vehicle's own collision is a
	# coarse CONVEX hull that encloses the boxes, so we exclude it (it can't self-block); FOREIGN walls
	# still block. Choosing the box by seated-state is what stops opening a door you can't see.
	if target.has_method("side_shape"):
		var veh: Node = target.vehicle() if target.has_method("vehicle") else null
		var inside: bool = veh != null and veh.has_method("is_occupied_by") and veh.is_occupied_by(player)
		var box: Node3D = target.side_shape(inside)
		if box == null:
			return true  # handle without assigned boxes: don't lock the door
		# Exclude the vehicle's coarse convex self-hull (it encloses the boxes, can't self-block); FOREIGN
		# walls still block.
		return not _line_of_sight_blocked(box.global_position, [veh])
	# Otherwise the target IS the solid we look at (a carriable): a solids ray must reach IT first — a
	# wall, a bed side or the bodywork in front is hit instead, so the target is not visible.
	return _first_solid_hit_is(target)

## True if a MASK_OBSTACLE ray from the eye toward `target` hits `target` ITSELF first (nothing solid
## in front of it). We only ignore ourselves; whatever the target rests in/on is NOT excluded, so you
## can't grab an object through the side of the bed it sits in — you must actually see it.
func _first_solid_hit_is(target: Node3D) -> bool:
	_ensure_los_ray()
	_los_ray.global_position = player.interact_ray.global_position
	var to_target: Vector3 = target.global_position - _los_ray.global_position
	# Aim a touch past the centre so a thin/small target is still crossed by the ray.
	_los_ray.target_position = to_target * 1.05
	_los_ray.clear_exceptions()
	_los_ray.add_exception(player)
	_los_ray.force_raycast_update()
	# Float32 precision at astronomic world coordinates makes this physics ray imprecise (same limit as
	# the door LOS / Jolt "dancing" bug): far from the origin it can miss the target or catch a body well
	# off the eye->target segment, so a grab is refused until you are almost inside the prop. The client
	# already aimed at it; validate in DOUBLE precision. A miss, or a hit BEYOND the target, counts as
	# visible; only a solid genuinely CLOSER than the target (a wall / bed side in front) blocks the grab.
	if not _los_ray.is_colliding():
		return true
	var c: Object = _los_ray.get_collider()
	if c == target or (c is Node and (target.is_ancestor_of(c) or (c as Node).is_ancestor_of(target))):
		return true
	if c is Node3D:
		var target_dist: float = _los_ray.global_position.distance_to(target.global_position)
		var hit_dist: float = _los_ray.global_position.distance_to(_los_hit_world_pos(c))
		return hit_dist > target_dist
	return false

## True if a solid wall stands between the eye and the carriable `prop`. Thin wrapper over `_can_see`
## for the carry call sites; tiny ore pieces detect unreliably, so we don't gate them on sight.
func _is_blocked_by_geometry(prop: Node) -> bool:
	if prop is Node3D and "type_name" in prop and prop.type_name == "miningrock":
		return false
	return not _can_see(prop)

## World position of the SPECIFIC collision shape the LOS ray hit — NOT the whole CollisionObject's
## origin. A building is a multi-cell StaticBody: get_collider() returns that body, whose origin sits at
## one corner, far from the wall you actually hit. Comparing THAT distance to the target wrongly reads
## the wall as "beyond" the target and lets you grab/open through it. The hit SHAPE's own transform is
## right at the wall. Node transforms are double precision here; get_collision_point() is not (Jolt
## float32 → km-off at astronomic coords). Falls back to the collider origin if the shape can't resolve.
func _los_hit_world_pos(c: Object) -> Vector3:
	if c is CollisionObject3D:
		var obj := c as CollisionObject3D
		var owner_id: int = obj.shape_find_owner(_los_ray.get_collider_shape())
		if owner_id != -1:
			return (obj.global_transform * obj.shape_owner_get_transform(owner_id)).origin
	if c is Node3D:
		return (c as Node3D).global_position
	return Vector3.ZERO

## Lazily create the body-only line-of-sight ray (a node, so force_raycast_update works in
## _process / input / server alike — direct_space_state is only valid during physics).
func _ensure_los_ray() -> void:
	if _los_ray != null:
		return
	_los_ray = RayCast3D.new()
	_los_ray.enabled = false
	_los_ray.top_level = true  # ignore the player's transform → target_position is a world delta
	_los_ray.collide_with_areas = false
	_los_ray.collide_with_bodies = true
	_los_ray.collision_mask = Globals.MASK_OBSTACLE  # solids only (world|vehicle|prop); player excluded via exceptions
	add_child(_los_ray)

## Release the carried prop: restore its physics, load it onto a truck bed if it was dropped into one,
## else drop it back into the world. Shared by the E-drop (server_action_received) and the out-of-reach
## auto-drop (_server_update_carried_item). Guarded so a deferred call after a drop is a no-op.
func _server_drop_carried_item() -> void:
	if player.hands_item == null:
		return
	print("player has an item in hands, dropping it")
	# Generic: let the object know it is no longer carried (issue #124).
	if player.hands_item.has_method("set_carried"):
		player.hands_item.set_carried(false)
	player.hands_item.remove_collision_exception_with(player)  # it can collide with us again
	_carry_ignore_vehicles(player.hands_item, false)  # clear any stale vehicle exceptions
	# Restore the physics state we changed while carrying (gravity / sleep / CCD).
	if player.hands_item.has_meta("pre_carry_gravity_scale"):
		player.hands_item.gravity_scale = player.hands_item.get_meta("pre_carry_gravity_scale")
		player.hands_item.remove_meta("pre_carry_gravity_scale")
	player.hands_item.can_sleep = true
	player.hands_item.continuous_cd = false
	# Restore the rotation damping we raised while carried, so it tumbles freely again once dropped.
	if player.hands_item.has_meta("pre_carry_angular_damp"):
		player.hands_item.angular_damp = player.hands_item.get_meta("pre_carry_angular_damp")
		player.hands_item.remove_meta("pre_carry_angular_damp")
	# If dropped before reaching the hand, restore the collision suppressed on pickup.
	if player.hands_item.has_meta("pre_carry_layer"):
		player.hands_item.collision_layer = player.hands_item.get_meta("pre_carry_layer")
		player.hands_item.remove_meta("pre_carry_layer")
	if player.hands_item.has_meta("pre_carry_mask"):
		player.hands_item.collision_mask = player.hands_item.get_meta("pre_carry_mask")
		player.hands_item.remove_meta("pre_carry_mask")
	# Drop INTO a bed -> load it onto that truck. We load it if we stand in the bed, OR if we
	# drop it from outside but it lands inside a nearby truck's cargo bay.
	if player.hands_item is RigidBody3D:
		var bed = _cargo_bed_for_drop(player.hands_item.global_position)
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

## Rotate the held object by `rot` (world-space) about its geometry CENTER rather than its body
## origin, so it spins in place instead of orbiting when the origin is off-center. The center is
## pinned to the hold spot each tick by _server_update_carried_item, so we keep it fixed here too
## (no lurch). The held body's angular axes are locked, so the new basis sticks.
func _rotate_held_about_center(rot: Basis) -> void:
	if not is_instance_valid(player.hands_item):
		return
	var item: RigidBody3D = player.hands_item
	var center: Vector3 = item.get_center_offset() if item.has_method("get_center_offset") else Vector3.ZERO
	var tf: Transform3D = item.global_transform
	var center_world: Vector3 = tf * center
	tf.basis = (rot * tf.basis).orthonormalized()
	tf.origin = center_world - tf.basis * center
	item.global_transform = tf

## Server: hold the carried item in front of the body (yaw only), driven toward the hold spot by
## velocity (physics-held carry B). The camera PITCH raises/lowers the spot vertically for stacking,
## and if the body is dragged out of grab reach (stuck behind a wall while we back off) it auto-drops.
func _server_update_carried_item(delta: float) -> void:
	if player.hands_item == null:
		return
	var item: RigidBody3D = player.hands_item
	# Auto-drop when the body is dragged out of reach: if it stays stuck (behind a wall) while we back
	# away, the gap to the grab point grows; once it passes the grab reach, let it go on its own. The
	# reparent inside the drop is illegal mid-physics-step, so defer it to the end of the frame.
	var eye: Vector3 = player.to_global(player.camera_pivot.position)
	if eye.distance_to(item.global_position) > player.interact_ray.target_position.length():
		call_deferred("_server_drop_carried_item")
		return
	# Body-relative hold spot (head height + front) — yaw only (issue #124) — to world, offset by the
	# geometry center so the object sits centered on that spot.
	var center: Vector3 = Vector3.ZERO
	if item.has_method("get_center_offset"):
		center = item.get_center_offset()
	var hold_world: Vector3 = player.to_global(player.camera_pivot.position + player.carry_offset) \
			- item.global_basis * center
	# Camera pitch raises/lowers the hold spot along the VERTICAL (up_direction) only — look up/down to
	# place the object higher/lower (e.g. stacking). The server has the replicated "head" pitch, so the
	# camera forward's vertical component gives the pitch ratio (+1 up, -1 down, 0 level). We amplify it
	# (gain) so the object climbs FASTER than the gaze — it sits above the crosshair, leaving the target
	# shelf visible under it — then saturate at the max lift.
	var pitch_ratio: float = (-player.camera_pivot.global_basis.z).dot(player.up_direction)
	var lift: float = clampf(pitch_ratio * _CARRY_PITCH_GAIN, -_CARRY_PITCH_LIFT, _CARRY_PITCH_LIFT)
	hold_world += player.up_direction * lift
	# Keep the hold spot inside the player's own free space: above the floor below AND below any ceiling
	# above (e.g. inside a container / building). BOTH rays start at the EYE — always in the free space —
	# so the downward one finds the floor and the upward one finds the ceiling. (The old guard cast DOWN
	# from 2.5 m above the hold spot; indoors that ray hit the CEILING from above and "rested" the object
	# on the roof, so looking up made it jump upward.)
	var up: Vector3 = player.up_direction
	var space = player.get_world_3d().direct_space_state
	var solids_mask := (1 << (Globals.LAYER_WORLD - 1)) | (1 << (Globals.LAYER_VEHICLE - 1))
	var excl: Array[RID] = [player.get_rid(), item.get_rid()]
	var hold_h: float = (hold_world - eye).dot(up)  # hold-spot height above the eye, along up
	var floor_hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, eye - up * 3.0, \
			solids_mask, excl))
	if floor_hit:
		var floor_h: float = (floor_hit.position - eye).dot(up) + _CARRY_GROUND_CLEARANCE
		if hold_h < floor_h:
			hold_world += up * (floor_h - hold_h)
			hold_h = floor_h
	var ceil_hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, eye + up * 3.0, \
			solids_mask, excl))
	if ceil_hit:
		var ceil_h: float = (ceil_hit.position - eye).dot(up) - _CARRY_CEILING_CLEARANCE
		if hold_h > ceil_h:
			hold_world += up * (ceil_h - hold_h)
	# Restore collision once it has reached our hands AND is clear of other solids. It travelled
	# collision-free so nothing interfered; turning it solid again while it OVERLAPS another body (picked
	# up from inside a pile, or the hand spot is inside a prop) makes the solver eject them violently and
	# sends the surrounding objects flying. So wait until it no longer overlaps anything before re-arming.
	var dist: float = item.global_position.distance_to(hold_world)
	if item.has_meta("pre_carry_layer") and dist < _CARRY_INHAND_DIST and not _carried_overlaps_solid(item):
		item.collision_layer = item.get_meta("pre_carry_layer")
		item.collision_mask = item.get_meta("pre_carry_mask")
		item.remove_meta("pre_carry_layer")
		item.remove_meta("pre_carry_mask")
	# Physics-held carry (B): steer the DYNAMIC body toward the hold spot by velocity. With a clear path
	# it reaches the spot in one step; the ground / a wall / a vehicle resists that velocity, so the body
	# naturally bumps them instead of clipping through. Cap the speed so a fast turn can't tunnel a wall.
	var vel: Vector3 = (hold_world - item.global_position) / delta
	if vel.length() > _CARRY_FOLLOW_MAX_SPEED:
		vel = vel.normalized() * _CARRY_FOLLOW_MAX_SPEED
	item.linear_velocity = vel
	# NB: angular velocity is NOT zeroed here — the body keeps the spin a bump imparts (heavily damped,
	# see _CARRY_ANGULAR_DAMP), so a carried object reacts to knocks instead of being rigidly locked.

## True if the carried body currently overlaps a solid (world / vehicle / prop / another player), so we
## can hold off re-arming its collision until it's clear — otherwise turning it solid inside a pile
## ejects the neighbours. The carrier is excluded (we already collision-except it). Iterates the body's
## OWN collision shapes; a query uses its own shape+mask, so the item's suppressed layer doesn't matter.
func _carried_overlaps_solid(item: RigidBody3D) -> bool:
	var space = item.get_world_3d().direct_space_state
	if space == null:
		return false
	var mask := (1 << (Globals.LAYER_WORLD - 1)) | (1 << (Globals.LAYER_PLAYER - 1)) \
			| (1 << (Globals.LAYER_VEHICLE - 1)) | (1 << (Globals.LAYER_PROP - 1))
	for owner_id in item.get_shape_owners():
		var xf: Transform3D = item.global_transform * item.shape_owner_get_transform(owner_id)
		for i in item.shape_owner_get_shape_count(owner_id):
			var shape: Shape3D = item.shape_owner_get_shape(owner_id, i)
			if shape == null:
				continue
			var q := PhysicsShapeQueryParameters3D.new()
			q.shape = shape
			q.transform = xf
			q.collision_mask = mask
			q.exclude = [item.get_rid(), player.get_rid()]
			q.margin = 0.0
			if not space.intersect_shape(q, 1).is_empty():
				return true
	return false

## Server-authoritative carry prompt: the server (which owns the collisions) decides what E
## will do from the player's replicated aim, and replicates "carry"/"drop"/"" to the owner —
## the client just displays it. Throttled so it's cheap (one ray per player, not per object).
func _server_update_carry_prompt(delta: float) -> void:
	_carry_prompt_timer -= delta
	if _carry_prompt_timer > 0.0:
		return
	_carry_prompt_timer = 0.1
	var state := _compute_carry_prompt()
	if state != player._carry_prompt:
		player._carry_prompt = state
		player.server_send_properties_to_client({"carry_prompt": state})

## What E would do right now (server side): if we hold something, "cargo" when the drop would load
## it onto a truck (it sticks), else "drop"; if our hands are empty, "carry" when we aim at a
## grabbable prop that is reachable (not carried by another, clear line of sight).
func _compute_carry_prompt() -> String:
	if player.hands_item != null:
		if _cargo_bed_for_drop(player.hands_item.global_position) != null:
			return "cargo"  # dropping here loads it into the bed (sticks)
		return "drop"
	player.interact_ray.force_raycast_update()
	var prop = player._aimed_carriable()
	if prop != null and prop.has_method("interact") and prop.interact(player) \
			and not _is_blocked_by_geometry(prop):
		return "carry"
	return ""

## Which truck bed should swallow a crate dropped at this world point: any truck whose designer
## loading zone contains it. Same rule whether we stand in the bed or reach over from outside — the
## zone (not the player's position) decides whether loading is allowed.
func _cargo_bed_for_drop(world_point: Vector3) -> Vehicle:
	for v in get_tree().get_nodes_in_group("vehicle"):
		if v is Vehicle and v.is_point_in_loading_zone(world_point):
			return v
	return null

## Safety net for CharacterBody tunnelling through the thin trimesh terrain on
## a fast fall.  Only acts when the player is CLEARLY below the crack-aware
## surface (a real fall-through) — normal standing rests on the polygon
## collision within the margin, so this never fires then and doesn't affect
## is_on_floor / jumping.  [param area] is the planet gravity Area3D.
func _catch_if_below_surface(area: Area3D) -> void:
	var planet := area.get_parent().get_parent()
	if planet == null or not is_instance_valid(planet):
		return
	if not planet.has_method("get") or planet.get("planet_data") == null:
		return
	var pdata = planet.planet_data
	if pdata == null:
		return
	var local_world: Vector3 = player.global_position - planet.global_position
	if local_world.length_squared() < 1.0:
		return
	var planet_basis: Basis = planet.global_transform.basis
	var local_body: Vector3 = planet_basis.inverse() * local_world
	var dir: Vector3 = local_body.normalized()
	var player_dist: float = local_body.length()
	var surface_dist: float = pdata.crack_aware_surface_dist(dir)
	if player_dist >= surface_dist - player._SURFACE_CATCH_MARGIN:
		return  # at/near or above the surface — the collision handles it
	player.global_position = planet.global_position + planet_basis * (dir * surface_dist)
	var up_world: Vector3 = (planet_basis * dir).normalized()
	var radial: float = player.velocity.dot(up_world)
	if radial < 0.0:
		player.velocity -= up_world * radial

## Deferred teleport onto a system (e.g. a teleporter target): reparent under
## `destination`, place the player at `local_pos` expressed in that node's frame,
## then emit the move AFTER the reparent so the server receives the position
## relative to the new parent. Deferred because reparenting during an Area3D
## signal callback is illegal, and the callback can fire repeatedly.
func _teleport_to_system(destination: Node, local_pos: Vector3) -> void:
	if destination == null or not is_instance_valid(destination):
		return
	if not player.is_inside_tree() or not destination.is_inside_tree():
		return
	if player.get_parent() != destination:
		player.reparent(destination)
	# Test without parent, to have the planet gorc enter on client side
	player.global_position = Vector3(
		local_pos.x + destination.global_position.x,
		local_pos.y + destination.global_position.y,
		local_pos.z + destination.global_position.z
	)
	emit_signal(
		"hs_server_move",
		player.client_uuid,
		snapped(player.position, Vector3(0.001, 0.001, 0.001)),
		snapped(player.global_rotation, Vector3(0.0001, 0.0001, 0.0001)),
		str(destination.uuid) if "uuid" in destination else "",
		player.is_parented
	)
