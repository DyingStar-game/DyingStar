class_name Teleporter
extends Node3D

## Dev cabin that sends you to a point of interest, or to coordinates you type in.
##
## Replaces the seven hard-coded pads (the `TELEPORT_TARGETS` wall): a destination is now chosen at
## runtime from the whole system rather than compiled in, and its height is resolved against the
## destination's real terrain instead of a cartesian offset copied by hand.
##
## SPLIT OF DUTIES — this script is the only place the two sides meet, and it keeps them apart:
##   CLIENT — builds nothing and decides nothing. It feeds [TeleporterUI] the catalogue, remembers
##            where the trip started (so "Return" needs no server state at all), and forwards the
##            chosen destination as a plain action.
##   SERVER — the only one that resolves a body, a height and a position, and the only one that moves
##            anybody. It re-validates everything: the payload names a place, never an outcome.
##
## The screen contract is [ScreenZone]'s: expose update_screen(data), plus the optional
## screen_look_target() and screen_focus_changed(). Same wiring as the mining depot.

## Key in [constant Globals.ENABLED_DEV_TOOLS]. It has no InputMap binding — the cabin is walked
## into, not pressed — so nothing in the controls menu looks for it; the entry is purely the switch.
const DEV_TOOL: StringName = &"teleporter"
## Metres above the ground the "Return" entry aims for. Same clearance the catalogue uses.
const RETURN_CLEARANCE_M: float = 2.0
## Metres of air left under a vehicle that travels with you: enough to settle onto its wheels.
const VEHICLE_CLEARANCE_M: float = 0.5
## Most vehicles one trip carries. A cabin holds one truck comfortably; the cap is only there so a
## shape query can never walk an unbounded list.
const MAX_VEHICLES: int = 8
## Physics frames between the player's arrival and the vehicles'.
##
## ⚠️ NOT cosmetic, and not a guess at a race. Moving both in the SAME tick asks GORC to work out two
## subscription changes from one batch, and it got it wrong in the measured way: the truck arrived
## correctly on the server — the database put it 2.5 m from the player — but the client logged
## `[client][STUCK] vehicle … never received scenename` and left it invisible forever. Separated, each
## move is an ordinary transition of the kind that works everywhere else in the game: the player
## arrives, then something drives into their zone.
const RIDER_DELAY_FRAMES: int = 3

## The system whose bodies this cabin offers. Every cabin can offer a different one; today there is
## only Tarsis, and [TeleportCatalog] discovers the rest the day there are more.
@export var system: String = "tarsis"

@onready var _ui: TeleporterUI = %TeleporterUI
@onready var _gui_3d: Node3D = $Gui3D
@onready var _interior: Area3D = $Interior

## Server: who pressed the button, handed over by the action router (never read from the payload).
var _actor: Player = null
## Server: a validated trip waiting for a physics frame to sweep the garage in. See _physics_process.
var _pending: Dictionary = {}
## Server: what the sweep found, and the trip it belongs to, while they wait their turn to follow.
var _riders: Array[Vehicle] = []
var _rider_trip: Dictionary = {}
var _rider_wait: int = 0


func _ready() -> void:
	# Physics processing is switched on only for the one frame a trip needs (see _physics_process);
	# a cabin does nothing per-tick the rest of the time.
	set_physics_process(false)
	if GameOrchestrator.is_server():
		return  # the headless server has no interface to build
	_ui.teleport_requested.connect(_on_ui_teleport_requested)
	_ui.set_enabled(Globals.is_dev_tool_enabled(DEV_TOOL))
	_ui.load_systems(TeleportCatalog.systems(), system)


## SERVER: the one frame where the garage can actually be measured.
##
## ⚠️ THE REASON THIS EXISTS. `get_world_3d().direct_space_state` is only usable inside a physics
## frame; from idle time it errors and the query never runs. update_screen() is called from the
## network handler and the move from call_deferred — neither is a physics frame, so the first
## version swept nothing and the truck was silently left behind, with the player teleporting fine.
## Exactly the trap the project has hit before with raycasts fired from _process.
##
## So: validate in update_screen, MEASURE here, and move from a deferred call — because the move
## reparents bodies, which is illegal during physics. Each step in the only place it is allowed.
func _physics_process(_delta: float) -> void:
	if not _pending.is_empty():
		var trip: Dictionary = _pending
		_pending = {}
		_riders = _vehicles_inside()  # the ONE place the space state answers
		call_deferred("_move_actor", trip["body"], trip["pos"])
		if _riders.is_empty():
			set_physics_process(false)
			return
		# The garage follows a few frames later, on its own — see RIDER_DELAY_FRAMES.
		_rider_trip = trip
		_rider_wait = RIDER_DELAY_FRAMES
		return
	if _rider_wait > 0:
		_rider_wait -= 1
		if _rider_wait == 0:
			set_physics_process(false)
			call_deferred("_move_riders")
		return
	set_physics_process(false)


# ---------------------------------------------------------------------------------------------
# Screen contract (see ScreenZone)
# ---------------------------------------------------------------------------------------------

## Where a player's camera should look while using this screen: the screen SURFACE, not the cabin's
## origin, which is metres away.
func screen_look_target() -> Node3D:
	return _gui_3d


## Told who is standing at the console. On the CLIENT this is when the "Return" entry can be filled
## in — the departure point is simply where that player is right now, so nothing has to be stored on
## the server or replicated back.
func screen_focus_changed(player: Player, focused: bool) -> void:
	if GameOrchestrator.is_server():
		return
	if not focused:
		return
	_ui.set_return_point(_departure_of(player))


## The action router hands over the player whose action this is, immediately before update_screen.
func set_screen_actor(player: Player) -> void:
	_actor = player


## SERVER: a destination was chosen. This is the authority path — everything is re-checked here, and
## the payload is treated as a request, never as an instruction.
func update_screen(data: Dictionary) -> void:
	if str(data.get("state", "")) != "teleport":
		return  # some other screen action; not ours
	# A dev tool is switched off where it RUNS, not where it is triggered: a client with an old build,
	# or one that simply skips the greyed-out interface, still gets nowhere.
	if not Globals.is_dev_tool_enabled(DEV_TOOL):
		push_warning("[Teleporter] refused: the teleporter is switched off (Globals.ENABLED_DEV_TOOLS)")
		return
	if not is_instance_valid(_actor):
		push_warning("[Teleporter] refused: no actor — the screen was not told who pressed")
		return
	var dest: TeleportDestination = TeleportDestination.from_payload(data)
	if not dest.is_valid():
		push_warning("[Teleporter] refused: '%s' is not a usable destination" % dest.describe())
		return
	var body: Planet = PlanetRegistry.find_by_name(dest.planet_name)
	if body == null:
		# Not a silent no-op: a body the network never created is exactly the case that used to end
		# with somebody floating in the dark wondering why nothing happened.
		push_warning("[Teleporter] refused: body '%s' is not in the network registry"
				% dest.planet_name)
		return
	var tile: Array = []
	var local_pos: Vector3 = TeleportGround.local_pos_for(body, dest, tile)
	# int, not the enum: the outcome comes back through an Array, so it arrives as a Variant.
	var outcome: int = int(tile[0]) if not tile.is_empty() else int(TeleportGround.Tile.COARSE)
	# Not a gate. Which pyramid level answered is worth SAYING — it is printed below — but it is not
	# grounds for refusing: the landing is computed with the same function the server's own anti-tunnel
	# clamp uses, so it agrees with the collision whatever level the height came from.
	print("[Teleporter] %s -> %s [%s] local (%.0f, %.0f, %.0f)"
			% [_actor.client_uuid, dest.describe(), TeleportGround.tile_text(outcome),
			local_pos.x, local_pos.y, local_pos.z])
	# Handed to the next physics frame, which is the only place the garage can be measured — see
	# _physics_process. It is that frame which then defers the move.
	_pending = {"body": body, "pos": local_pos, "mode": dest.height_mode}
	set_physics_process(true)


## SERVER, deferred: send the actor. Deferred because it reparents a body.
func _move_actor(body: Planet, local_pos: Vector3) -> void:
	if not is_instance_valid(_actor) or not is_instance_valid(body):
		return
	_actor.server_teleport_to(body, local_pos)


## SERVER, deferred: send what was parked in the garage, a few frames behind the actor.
##
## The vehicles have NOT moved since the sweep — they are still sitting in the cabin — so their
## offsets are read here, at the last moment, rather than captured earlier.
func _move_riders() -> void:
	var trip: Dictionary = _rider_trip
	var riders: Array[Vehicle] = _riders
	_rider_trip = {}
	_riders = []
	var body: Planet = trip.get("body") as Planet
	if not is_instance_valid(body):
		return
	var local_pos: Vector3 = trip["pos"]
	# Everything keeps its layout: a truck parked five metres behind you arrives five metres behind
	# you. The offset is taken in the CABIN's frame and replayed in a frame built at the landing site,
	# because the two are on opposite sides of a sphere — a world-axes offset would arrive sideways.
	var cabin_inv: Basis = global_transform.basis.orthonormalized().inverse()
	var landing: Basis = _frame_for_up(local_pos.normalized())
	var moved: int = 0
	for vehicle: Vehicle in riders:
		# Frames have passed since the sweep: a vehicle could have been deleted in between.
		if not is_instance_valid(vehicle) or not vehicle.is_inside_tree():
			continue
		moved += 1
		var offset: Vector3 = cabin_inv * (vehicle.global_position - global_position)
		var spot: Vector3 = local_pos + landing * Vector3(offset.x, 0.0, offset.z)
		# Heading is carried the same way the offset is: read in the cabin's frame, replayed in the
		# landing one. A truck that was nose-out of the door arrives nose-out of nothing in particular,
		# but at least it does not arrive across its own axis.
		var nose: Vector3 = cabin_inv * (-vehicle.global_basis.z)
		_place_vehicle(vehicle, body, spot, offset.y, int(trip["mode"]),
				landing * Vector3(nose.x, 0.0, nose.z))
	print("[Teleporter] %d vehicle(s) followed" % moved)


## Put [param vehicle] down at [param spot] (planet-local) on [param body], upright on that spot's own
## ground and pointing along [param nose] (planet-local, already tangent to the surface).
func _place_vehicle(vehicle: Vehicle, body: Planet, spot: Vector3, lift: float,
		height_mode: int, nose: Vector3) -> void:
	var dir: Vector3 = spot.normalized()
	var radius: float = spot.length()
	if height_mode == TeleportDestination.Height.GROUND and body.planet_data != null:
		# Its OWN ground, not the actor's: over ten metres of offset the terrain has already moved.
		TeleportGround.ensure_tile(body.planet_data, dir)
		radius = body.planet_data.crack_aware_surface_dist(dir) + maxf(lift, 0.0) + VEHICLE_CLEARANCE_M
	var local: Vector3 = dir * radius
	if vehicle.get_parent() != body:
		vehicle.reparent(body)
	# A RigidBody that was asleep stays asleep through a teleport, and both PropNet.server_tick and
	# Vehicle._replicate_transform skip a sleeping body — it would arrive on the server and nowhere
	# else, which is the least debuggable failure available.
	vehicle.sleeping = false
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	vehicle.global_transform = Transform3D(
			_basis_facing(dir, nose),
			body.global_position + body.global_basis * local)
	# The parent_id and the new position go out together on the next tick: Vehicle._replicate_transform
	# already puts them in ONE payload whenever the parent changes, which is exactly this case.


## SERVER: the vehicles parked inside the cabin. Swept on demand with a shape query — the project's
## rule is one active monitor, the player, so a volume like this is never left monitoring.
func _vehicles_inside() -> Array[Vehicle]:
	var out: Array[Vehicle] = []
	var shape: CollisionShape3D = _interior.get_node_or_null("CollisionShape3D")
	if shape == null or shape.shape == null:
		return out
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return out
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape.shape
	query.transform = shape.global_transform
	query.collision_mask = 1 << (Globals.LAYER_VEHICLE - 1)
	query.collide_with_bodies = true
	for hit in space.intersect_shape(query, MAX_VEHICLES):
		var vehicle := hit.get("collider") as Vehicle
		if vehicle != null and not out.has(vehicle):
			out.append(vehicle)
	return out


## An orthonormal frame whose Y is [param up]. The reference axis is swapped near the poles, where the
## usual one is parallel to up and the cross product would collapse to zero.
static func _frame_for_up(up: Vector3) -> Basis:
	var reference: Vector3 = Vector3.UP if absf(up.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var east: Vector3 = reference.cross(up).normalized()
	return Basis(east, up, up.cross(east).normalized())


## Standing on [param up] and facing [param nose]. Godot's forward is -Z, so that is the column the
## heading goes into — negated. A nose parallel to up carries no heading at all (it happens when a
## vehicle is nose-down), and then any frame will do.
static func _basis_facing(up: Vector3, nose: Vector3) -> Basis:
	var forward: Vector3 = nose - up * nose.dot(up)
	if forward.length_squared() < 1e-6:
		return _frame_for_up(up)
	forward = forward.normalized()
	return Basis(forward.cross(up).normalized(), up, -forward)


# ---------------------------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------------------------

## CLIENT: forward the chosen destination. The cabin adds nothing of its own — the server resolves
## the body, the ground and the position from the lon/lat alone.
func _on_ui_teleport_requested(payload: Dictionary) -> void:
	if GameOrchestrator.is_server():
		return
	var player: Player = _local_player()
	if player == null:
		return
	# Capture the departure BEFORE leaving, so "Return" is available the moment we arrive. Purely
	# client-side: a return trip is just another destination, so nothing needs to be kept server-side.
	_ui.set_return_point(_departure_of(player))
	var action: Dictionary = payload.duplicate()
	action["action"] = "screen_state"
	action["state"] = "teleport"
	player.client_send_action_to_server(action)


## Where [param player] is standing, as a destination that would bring them back here.
func _departure_of(player: Player) -> TeleportDestination:
	var body: Planet = _planet_above(player)
	if body == null or body.planet_data == null:
		return null  # in transit or in deep space: there is no lon/lat to come back to
	var lonlat: Vector2 = body.lonlat_of(player.global_position)
	var where: String = body.display_name if body.display_name != "" else body.planet_data.planet_name
	return TeleportDestination.new(
			"Departure point", body.planet_data.planet_name, lonlat.x, lonlat.y,
			RETURN_CLEARANCE_M, TeleportDestination.Height.GROUND,
			TeleportDestination.Kind.RETURN, where)


static func _planet_above(node: Node) -> Planet:
	var walk: Node = node
	while walk != null:
		if walk is Planet:
			return walk as Planet
		walk = walk.get_parent()
	return null


static func _local_player() -> Player:
	var agent = NetworkOrchestrator.network_agent
	if agent == null or not "player_entity" in agent:
		return null
	return agent.player_entity as Player
