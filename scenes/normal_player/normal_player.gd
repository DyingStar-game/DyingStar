class_name Player

extends CharacterBody3D

signal hs_client_action_move
signal hs_server_move
signal hs_client_action_pressed
signal display_debug(show: bool)
signal hs_server_player_update

@warning_ignore("unused_signal")
signal client_action_requested(datas: Dictionary)

const MOVE_FORWARD: String = "move_forward"
const MOVE_BACK: String = "move_back"
const MOVE_LEFT: String = "move_left"
const MOVE_RIGHT: String = "move_right"
const JUMP: String = "jump"
## Seconds with no gravity area before we treat it as real 0g (ignores brief reparent gaps).
const ZERO_G_GRACE: float = 0.2
const CROUCH: String = "crouch"
const SPRINT: String = "sprint"
const PAUSE: String = "pause"

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

# Hand brake: a long press on the brake (Space) at low speed toggles the vehicle's hand brake.
const HANDBRAKE_HOLD_SECS: float = 0.4
const HANDBRAKE_MAX_KMH: float = 3.0
## Hide a remote player's name tag beyond this distance from the local camera.
const NAME_TAG_MAX_DISTANCE: float = 25.0
## How far below the crack-aware terrain surface counts as a fall-through
## (see _catch_if_below_surface).
const _SURFACE_CATCH_MARGIN := 3.0

# Dev spawn wheel: data key -> spawn params. Crates replicate as the "box" type (box_def.json) unless
# they carry their own type (palette_container); only the scene differs — one table drives both the
# wheel submenus and the spawn (DRY).
const SPAWN_PROPS := {
	"rock": {"scene": "rock/rock_mining_small", "type": "miningrock", "z": 5.5, "y": 1.2},
	"rock_medium": {"scene": "rock/rock_mining_medium", "type": "miningrock", "z": 6.0, "y": 4.0},
	"rock_large": {"scene": "rock/rock_mining_large", "type": "miningrock", "z": 9.0, "y": 6.0},
	"box": {"scene": "testbox/box_50cm", "type": "box", "z": 1.5, "y": 2.0},
	"palette_container": {"scene": "cargo/palette_container", "type": "palette_container", "z": 2.5, "y": 2.0},
	"pallet_plate": {"scene": "cargo/pallet_plate", "type": "box", "z": 2.5, "y": 2.0},
	"pallet_crate": {"scene": "cargo/pallet_crate", "type": "box", "z": 2.5, "y": 2.0},
	"pallet_benne": {"scene": "cargo/pallet_benne", "type": "box", "z": 2.5, "y": 2.0},
	"pallet_liquid": {"scene": "cargo/pallet_liquid", "type": "box", "z": 2.5, "y": 2.0},
}

@export_group("Controls map names")

@export_group("Customizable player stats")
## Body mass (kg) added to a vehicle's total weight when seated. Mass is gravity-independent
## (75 kg everywhere); only the WEIGHT changes with gravity. CharacterBody3D has no built-in mass.
@export var mass: float = 75.0
@export var walk_back_speed: float = 1.5
@export var walk_speed: float = 2.5
@export var player_thruster_force = 10
@export var sprint_speed: float = 5.0
@export var crouch_speed: float = 1.5
# Movement speed multiplier while carrying an ore (issue #124): slower with hands full.
@export var carry_speed_factor: float = 0.5
## Where a carried item floats, relative to the player body (issue #124): head height, a
## bit below the eye line and ahead. Body-relative (yaw only, no camera pitch).
@export var carry_offset: Vector3 = Vector3(0.0, -0.2, -1.2)
@export var jump_height: float = 1.0
@export var acceleration: float = 10.0
@export var arm_length: float = 0.5
@export var regular_climb_speed: float = 6.0
@export var fast_climb_speed: float = 8.0
@export_range(0.0, 1.0) var view_bobbing_amount: float = 1.0
@export_range(1.0, 10.0) var camera_sensitivity: float = 2.0

@export_range(0.0, 0.5) var camera_start_deadzone: float = .2
@export_range(0.0, 0.5) var camera_end_deadzone: float = .1

@export var gravity = 0.0

var client_uuid: String = ""

var player_display_name: String = ""

var input_direction: Vector2
var movement_strength: float
var mouse_motion: Vector2
var is_jumping: bool = false

var spawn_position: Vector3 = Vector3.ZERO
var spawn_up: Vector3 = Vector3.UP

var can_interact: bool = false

var health: int = 100
var stamina: int = 100
var hunger: int = 100
var thirst: int = 100
var integrity: int = 3

var gravity_parents: Array[Area3D]

var last_basis: Basis
var remote_player: bool = false
var input_from_server: Dictionary = {
	"input_direction": Vector2.ZERO,
	"rotation": Vector3.ZERO
}
var new_input_from_server: bool = false

var client_last_input_direction = Vector2.ZERO
var client_last_global_rotation = Vector3.ZERO

var is_parented: bool = false

# to disable player input when piloting vehicule/ship
var active = false
# Server-authoritative: true while seated in a vehicle. Blocks walking on the SERVER (which
# never sets `active` true). Set by Vehicle.server_enter / server_exit.
var piloting: bool = false

var hands_item: Node3D = null

# Admin cleanup tool (key 2). Built at runtime for the local player only (see _ready).
var admin_cleanup_tool: AdminCleanupTool = null

# The 3D screen (e.g. a mining depot) the player is currently in front of, or null. Set
# by the screen's interaction Area; while set, the mouse is freed to click the screen.
var screen_interacting = null
# World position of that screen, so the camera can turn to face it while interacting.
var screen_position: Vector3 = Vector3.ZERO

var _display_debug: bool = false

## Consecutive server ticks this player has been settled (no input, on floor,

# Last camera pitch ("head" player property) sent to the server, throttled.
var _last_head_sent: float = INF
# Seconds the player has had NO gravity area. A reparent (e.g. leaving a spawn apartment) drops all
# gravity areas for a frame or two while the body re-enters PlanetGravity; we only switch to the 0g
# control scheme (which zeroes the camera pitch) after the gravity has really been gone this long,
# so that blip doesn't snap the look back to the horizon.
var _no_gravity_time: float = 0.0
var _interp := NetInterpolator.new()  # smooths a REMOTE player's replicated movement
# Owner-local prediction of "am I carrying?", to stow/unstow the perforator immediately
# (the server broadcasts the stow to OTHER players; the owner doesn't echo to itself).
var _owner_carrying: bool = false

# Created lazily: a body-only ray for the server's carry line-of-sight checks (a node, so
# force_raycast_update works in any context — direct_space_state is only valid during physics).

# Carry prompt, decided by the SERVER (it owns the collisions) and replicated to the owner:
# "" / "carry" / "drop" / "cargo" (cargo = dropping here loads it onto a truck). The client only
# displays it — it never computes reachability itself.
var _carry_prompt: String = ""

# Behaviour strategy for this player (Strategy pattern), created once at spawn: PlayerServer on the
# dedicated server, PlayerClient on a client (owner + remote). Role-specific logic lives there; this
# body stays a thin facade over the shared nodes/state. Typed as Node — GDScript duck-types the calls.
var _role: Node = null

# Dev spawn wheel (radial menu), owner only — hold the spawn key to pick what to spawn.
var _spawn_wheel: RadialMenu = null

# Owner: uuid of the vehicle we are seated in ("" = on foot). Set when we take a seat.
var _seat_vehicle_uuid: String = ""
# Owner: the local vehicle replica (for the driver HUD / messages).
var _seat_vehicle_node: Node3D = null
# The VehicleSeat we occupy (driver or passenger); we ride its sit point each frame. Set
# on the client when we enter, on the server by Vehicle.server_enter. Null = on foot.
var _seat_node: Node3D = null
# True when our seat is the driver seat (drive input + HUD + R). Passenger = just rides.
var _seat_is_driver: bool = false
# The VehicleSeat box the player stands in (set by our own AreaDetector); E takes that seat.
var _nearby_seat: Node = null
# Remote player's name tag, drawn in 2D screen space (see _setup_name_tag) instead of a 3D
# billboard: at planetary world coordinates the GPU renders in single precision, so a 3D label
# shimmers as the camera moves. Projecting the head to the screen on the CPU (double precision)
# and drawing a plain 2D Label is rock-steady.
var _name_tag: Label = null
# The Vehicle whose cargo bay we are standing in on foot (our AreaDetector reports it). Used both
# for the bed-walker weight (server) and to load a crate we drop while standing in it.
var _in_vehicle_bed: Node = null
var _last_throttle: float = INF  # last drive input sent (to send only on change)
var _last_steer: float = INF
var _last_brake: bool = false
var _space_held_time: float = 0.0  # driver: how long the brake (Space) has been held
var _handbrake_sent: bool = false  # driver: hand brake toggle already fired for this hold
var _seated_saved: bool = false
# Fallback walking-state collision (the scene sets layer=player / mask=MASK_SOLID; set_seated saves
# the real values before zeroing). Kept in sync with Globals so a restore-before-save can't fall back
# to the wrong layer.
var _saved_collision_layer: int = 1 << (Globals.LAYER_PLAYER - 1)
var _saved_collision_mask: int = Globals.MASK_SOLID


@onready var camera = $CameraPivot/Camera3D

@onready var labelx: Label = $UserInterface/Debug/LabelXValue
@onready var labely: Label = $UserInterface/Debug/LabelYValue
@onready var labelz: Label = $UserInterface/Debug/LabelZValue
@onready var astronaut: Node3D = $Placeholder_Collider/Astronaut
@onready var interact_ray: RayCast3D = $CameraPivot/Camera3D/InteractRay
@onready var interact_label: Label = $UserInterface/HUD/InteractLabel
@onready var camera_pivot: Node3D = $CameraPivot

@onready var direct_chat: DirectChat = $UserInterface/DirectChat

@onready var box4m: PackedScene = preload("res://scenes/props/testbox/box_4m.tscn")
@onready var box50m: PackedScene = preload("res://scenes/props/testbox/box_50cm.tscn")
@onready var is_inside_box4m: bool = false

@onready var flashlight: SpotLight3D = $CameraPivot/Camera3D/Torch

# Mining gameplay (perforator equip, aim, perforation) is encapsulated in the
# MiningTool component (scene child). Networking stays here (see _ready wiring).
@onready var mining_tool: MiningTool = $MiningTool

func _enter_tree() -> void:
	if remote_player:
		position = spawn_position
		$UserInterface.visible = false
		# Don't hide CameraPivot: its Torch (SpotLight3D) lives under it, and a hidden ancestor would
		# keep a remote player's flashlight dark even when its replicated state is ON. The camera is
		# made non-current in _ready, so it never renders for us anyway.

	elif not OS.has_feature("dedicated_server"):
		NetworkOrchestrator.set_player_global_position.connect(_set_player_global_position)
	else:
		# server side
		$UserInterface.visible = false
		$CameraPivot.visible = false

func _ready() -> void:
	prints("Player", name, "spawned at", spawn_position, "on server" if GameOrchestrator.is_server() else "on client")

	# Mining tool: build its equipment mount + perforator from our camera rig, and
	# relay its replicated-state requests to the server + its aim signal to the UI.
	mining_tool.setup(camera_pivot, camera)
	mining_tool.sync_requested.connect(client_send_action_to_server)
	mining_tool.aiming_changed.connect($UserInterface.set_aiming)

	# Strategy: pick this player's behaviour ONCE — authority on the dedicated server, presentation
	# (owner + remote) on a client. The role is a child node driving this body; logic moves into it
	# incrementally. Empty for now, so behaviour is unchanged.
	_role = PlayerServer.new() if OS.has_feature("dedicated_server") else PlayerClient.new()
	_role.name = "Role"
	_role.player = self
	add_child(_role)
	_role.setup()

	if remote_player:
		camera.current = false
		_setup_name_tag(str(name))
		return

	if not OS.has_feature("dedicated_server"):
		# Dev spawn wheel: hold the spawn key (T) to pick what to spawn.
		_spawn_wheel = RadialMenu.new()
		_spawn_wheel.title = "Spawn"
		$UserInterface.add_child(_spawn_wheel)
		# The spawn-wheel handlers live on the client role (created just above; it IS a PlayerClient here).
		_spawn_wheel.option_selected.connect((_role as PlayerClient)._on_spawn_selected)

		# Admin cleanup tool (key 2): raycast + red aim line, left click deletes the
		# targeted player-spawned prop (rock / box / depot) down to the database.
		admin_cleanup_tool = AdminCleanupTool.new()
		add_child(admin_cleanup_tool)
		admin_cleanup_tool.setup(camera, self)

		global_position = spawn_position
		look_at(global_transform.origin + Vector3.FORWARD, spawn_up)

		position = spawn_position
		global_transform = Globals.align_with_y(global_transform, spawn_up)

		client_uuid = Globals.player_uuid
		self.set_meta("client_uuid", Globals.player_uuid)

		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		camera.current = true

		camera.make_current()
		(_role as PlayerClient)._force_temp_sky_environment()
		# Apply the saved field of view, and follow live changes from the settings menu.
		camera.fov = SettingsManager.get_fov()
		SettingsManager.fov_changed.connect((_role as PlayerClient)._on_fov_changed)
		# our own name tag is never created (only remote players get one)
		astronaut.visible = false
		interact_label.hide()
		connect_area_detect()
		active = false

		await get_tree().create_timer(5).timeout

		update_last_basis()

		active = true

		display_debug.emit(true)
		_display_debug = true

		var loading_node = get_tree().root.get_node("Loading")
		if loading_node:
			loading_node.queue_free()

		GameOrchestrator.stop_menu_music()
	else:
		position = spawn_position
		connect_area_detect()
		update_last_basis()

func set_uuid(uuid: String) -> void:
	client_uuid = uuid
	self.set_meta("client_uuid", uuid)

func connect_area_detect():
	if OS.has_feature("dedicated_server"):
		print("Connecting area detector on server side")
	$AreaDetector.monitoring = true
	# The single active monitor: scan ONLY the `zone` layer, where every passive detection zone lives
	# (seats, cargo bay, gravity, spawn). They are monitorable-only; the player does all the looking.
	# Behaviour is routed by group (gravity / spawn / vehicle_seat / vehicle_cargo).
	$AreaDetector.collision_mask = Globals.MASK_PROBE
	if not $AreaDetector.area_entered.is_connected(_on_area_detector_area_entered):
		$AreaDetector.area_entered.connect(_on_area_detector_area_entered)
	if not $AreaDetector.area_exited.is_connected(_on_area_detector_area_exited):
		$AreaDetector.area_exited.connect(_on_area_detector_area_exited)

func get_current_gravity_parent() -> Node3D:
	if gravity_parents.is_empty(): return null
	return gravity_parents.back()

func apply_parent_movement() -> void:
	var gravity_parent = get_current_gravity_parent()
	if !gravity_parent: return

	var current_basis = gravity_parent.global_transform.basis
	var delta_rot = current_basis * last_basis.inverse()

	# rotate the position with the planet
	var local_pos = global_position - gravity_parent.global_position
	global_position = gravity_parent.global_position + delta_rot * local_pos

	# rotate the orientation too
	global_transform.basis = delta_rot * global_transform.basis

	#print(surface_motion)


func update_last_basis() -> void:
	var gravity_parent = get_current_gravity_parent()
	if !gravity_parent: return

	last_basis = gravity_parent.global_transform.basis


func server_set_input(input_dir: Vector2, newrotation: Vector3) -> void:
	input_from_server["input_direction"] = input_dir
	input_from_server["rotation"] = newrotation
	new_input_from_server = true

## Disable our collision while seated so we don't shove the vehicle's physics body.
func set_seated(seated: bool) -> void:
	if seated:
		if not _seated_saved:
			_saved_collision_layer = collision_layer
			_saved_collision_mask = collision_mask
			_seated_saved = true
		collision_layer = 0
		collision_mask = 0
	else:
		collision_layer = _saved_collision_layer
		collision_mask = _saved_collision_mask
		_seated_saved = false


## Feed a REMOTE player its latest server transform (entity interpolation). The position is
## local (relative to the parent); the rotation arrives global, so convert it to the parent's
## frame before handing it to the interpolator (which works in local space).
## Owner on foot: feed our server-driven position so it is smoothed (position only — the
## mouse look stays immediate). No client prediction yet, so this trades a touch of lag for
## no saccades.
func net_set_local_target(local_pos: Vector3) -> void:
	_interp.set_position_target(self, local_pos)


func net_set_target(local_pos: Vector3, global_rot: Vector3) -> void:
	var target_basis := Basis.from_euler(global_rot)
	var parent := get_parent()
	if parent is Node3D:
		target_basis = (parent as Node3D).global_basis.inverse() * target_basis
	_interp.set_target(self, local_pos, target_basis)

## Re-snap the interpolation after a reparent (the local frame changed).
func net_reset_interp() -> void:
	_interp.snap_next()

func _ride_seat(seat: Node3D) -> void:
	var eye: Transform3D = seat.sit_transform()
	var veh: Node = seat.vehicle() if seat.has_method("vehicle") else null
	if veh != null and get_parent() == veh:
		# Parented to the vehicle: ride in LOCAL space so we move WITH it by transform
		# inheritance (no per-frame world fight against the parent's smoothing) — kills the jitter.
		var local_eye: Transform3D = (veh as Node3D).global_transform.affine_inverse() * eye
		transform.basis = local_eye.basis
		transform.origin = local_eye.origin - local_eye.basis * camera_pivot.position
	else:
		global_transform.basis = eye.basis
		global_position = eye.origin - eye.basis * camera_pivot.position
	# Free look from the seat: the mouse turns the camera pivot (yaw + pitch) relative to the
	# vehicle forward, so the view is no longer locked straight ahead.
	camera_pivot.rotation.y += mouse_motion.x * camera_sensitivity
	camera_pivot.rotation.x = clampf(
		camera_pivot.rotation.x + mouse_motion.y * camera_sensitivity,
		deg_to_rad(-80.0), deg_to_rad(80.0))
	mouse_motion = Vector2.ZERO
	velocity = Vector3.ZERO

func should_listen_input() -> bool:
	return not (direct_chat.is_shown || MenuConfig.is_shown)

## Returns surface gravity scaled by inverse-square distance from the area centre.
## At the surface (dist == gravity_point_unit_distance) the result equals area.gravity.
func _compute_gravity(area: Area3D) -> float:
	if not area.gravity_point:
		return area.gravity
	var planet_radius := area.gravity_point_unit_distance
	var dist := global_position.distance_to(area.global_position)
	if dist <= 0.0:
		return area.gravity
	return area.gravity * (planet_radius / dist) * (planet_radius / dist)




func orient_player():
	global_transform = global_transform.interpolate_with(Globals.align_with_y(global_transform, up_direction), 0.3)

func set_player_name(player_name):
	if _name_tag != null:
		_name_tag.text = str(player_name)

func get_player_name():
	pass

## Build the 2D screen-space name tag for a remote player. A CanvasLayer keeps it in screen space
## (immune to the 3D camera), and _update_name_tag positions it over the head every frame.
func _setup_name_tag(player_name: String) -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_name_tag = Label.new()
	_name_tag.text = player_name
	_name_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_tag.add_theme_font_size_override("font_size", 15)
	_name_tag.add_theme_color_override("font_outline_color", Color.BLACK)
	_name_tag.add_theme_constant_override("outline_size", 6)
	_name_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_name_tag)

## Project the head position to the screen (CPU, double precision) and place the 2D tag there,
## centered over the head and hidden when the player is behind the camera.
func _update_name_tag() -> void:
	if _name_tag == null:
		return
	var cam := get_viewport().get_camera_3d()
	var head: Vector3 = global_position + global_transform.basis.y * 2.2
	# Hide when behind the camera or farther than the cutoff (too far to read anyway).
	if cam == null or cam.is_position_behind(head) \
			or global_position.distance_to(cam.global_position) > NAME_TAG_MAX_DISTANCE:
		_name_tag.visible = false
		return
	_name_tag.visible = true
	_name_tag.position = cam.unproject_position(head) - _name_tag.size * 0.5

func _on_area_detector_area_entered(area: Area3D) -> void:
	if area.is_in_group("gravity"):
		if area.name == "PlanetGravity":
			var planet = area.get_parent().get_parent()
			#reparent(planet)
			# call_deferred("reparent", planet)
			is_parented = true
			emit_signal(
				"hs_server_move",
				client_uuid,
				snapped(position, Vector3(0.001, 0.001, 0.001)),
				snapped(global_rotation, Vector3(0.0001, 0.0001, 0.0001)),
				planet.uuid,
				is_parented
			)
		gravity_parents.push_back(area)
	elif area.is_in_group("vehicle_seat"):
		# Our own monitor walked into a seat box: remember it so E takes that seat (client prompt).
		_nearby_seat = area
	elif area.is_in_group("vehicle_cargo"):
		# We stepped into a bed on foot: add our weight to the load (server-authoritative), remember
		# the bed so a dropped crate loads onto this truck, and RIDE it (become a child of the truck
		# so we don't slide). Reparent is deferred — it's illegal inside an Area3D signal callback.
		var veh := area.get_parent()
		if veh is Vehicle:
			_in_vehicle_bed = veh
			veh.add_bed_player(self)

func _on_area_detector_area_exited(area: Area3D) -> void:
	if area.is_in_group("gravity"):
		if gravity_parents.has(area):
			gravity_parents.erase(area)
	elif area.is_in_group("vehicle_seat"):
		if _nearby_seat == area:
			_nearby_seat = null
	elif area.is_in_group("vehicle_cargo"):
		var veh := area.get_parent()
		if veh is Vehicle:
			if _in_vehicle_bed == veh:
				_in_vehicle_bed = null
			veh.remove_bed_player(self)
	elif area.is_in_group("spawn"):
		if not OS.has_feature("dedicated_server"):
			return
		var new_parent = area.get_parent().get_parent()
		# Deferred reparent + move sync: reparenting during the Area3D signal
		# callback is illegal ("busy adding/removing children"), and area_exited
		# can fire several times -> overlapping reparents crash the node while out
		# of tree. The move event MUST be emitted AFTER the reparent so the local
		# position is expressed in the new parent's frame; otherwise the server
		# places us with the old local position under the new parent uuid and
		# teleports us.
		call_deferred("_safe_reparent_and_sync", new_parent)
		# if gravity_parents.has(area):
		# 	gravity_parents.erase(area)

## Reparent guarded against invalid states (node/parent out of tree, already
## parented, repeated area_exited events) to avoid a server segfault, then emit
## the move so the server receives the position relative to the new parent.
func _safe_reparent_and_sync(new_parent: Node) -> void:
	print("YOLO REPARENT")
	if new_parent == null or not is_instance_valid(new_parent):
		return
	if not is_inside_tree() or not new_parent.is_inside_tree():
		return
	if get_parent() != new_parent:
		reparent(new_parent)
		emit_signal(
			"hs_server_move",
			client_uuid,
			snapped(position, Vector3(0.001, 0.001, 0.001)),
			snapped(global_rotation, Vector3(0.0001, 0.0001, 0.0001)),
			# Robust to the scene layout: a parent without a uuid (e.g. a grouping/test-zone node) = "".
			str(new_parent.uuid) if "uuid" in new_parent else "",
			true
	)

func _set_player_global_position(pos, rot):
	global_position = pos
	global_rotation = rot

# Send the properties of the player from godot server to horizon / client
# for example, the health, stamina, etc...
func server_send_properties_to_client(data: Dictionary):
	emit_signal(
		"hs_server_player_update",
		client_uuid,
		data,
	)

## Put the mining tool away. Used for tool exclusivity: selecting the admin cleanup tool
## (key 2) stows the perforator before showing itself.
func stow_mining_tool() -> void:
	if mining_tool != null:
		mining_tool.set_equipped(false)

# Send action of the client to the server part (Horizon / godot server)
# data example:
# {
#     "action": "jump"
# }
func client_send_action_to_server(data: Dictionary):
	emit_signal(
		"client_action_requested",
		data,
	)

# receive the properties sent by the server part (Horizon / godot server)
# this function is used to update the properties of the player onm client side
func client_channel_data_update(data: Dictionary) -> void:
	if data.has("position"):
		position = Vector3(
			data["position"]["x"],
			data["position"]["y"],
			data["position"]["z"]
		)
	if data.has("rotation"):
		rotation = Vector3(
			data["rotation"]["x"],
			data["rotation"]["y"],
			data["rotation"]["z"]
		)
	if data.has("flashlight"):
		flashlight.visible = bool(data["flashlight"])  # replicated torch state (owner + remotes)
	if data.has("carry_prompt") and not remote_player:
		_carry_prompt = str(data["carry_prompt"])  # server-decided E prompt for the owner
	if data.has("action"):
		match data["action"]:
			JUMP:
				is_jumping = true
	# Replicated mining state (tool visibility, camera aim, perforation) is applied
	# on remote players by the MiningTool component.
	if remote_player:
		mining_tool.apply_remote(data)
	elif data.has("carrying"):
		# Owner: reconcile the optimistic carry prediction with the server's verdict
		# (e.g. a missed pickup) so we never get stuck stowed (issue #124).
		var server_carrying := bool(data["carrying"])
		if server_carrying != _owner_carrying:
			_owner_carrying = server_carrying
			mining_tool.set_stowed(server_carrying)






## The carriable prop under the crosshair, or null. Checks the hit body itself AND its parent:
## a prop's collision can be the root (which carries interact(), e.g. a crate in a truck bed where
## get_parent() is the vehicle) or a child shape (parent carries interact()). (#124)
func _aimed_carriable() -> Node:
	if not interact_ray.is_colliding():
		return null
	var hit = interact_ray.get_collider()
	if hit == null:
		return null
	var prop: Node = null
	if hit.has_method("interact") and "uuid" in hit:
		prop = hit
	else:
		var p = hit.get_parent()
		if p != null and p.has_method("interact") and "uuid" in p:
			prop = p
	if prop == null:
		return null
	# NOTE: no line-of-sight check here — the client has no wall collision (collisions are
	# server-side), so it can't tell a wall is in the way. The SERVER re-checks line of sight
	# before granting the grab (see server_action_received / _is_blocked_by_geometry).
	# Don't offer a prop already carried by ANOTHER player (it IS reparented under them on our
	# client, so its parent is that Player — this is knowable without collision).
	var prop_parent = prop.get_parent()
	if prop_parent is Player and prop_parent != self:
		return null
	return prop












## Owner-local: predict whether the carry key picks up or drops, to stow/unstow the
## perforator right away. The server stays authoritative (it may reject, e.g. a piece
## already taken); a mismatch self-corrects on the next interaction.
func _predict_carry_stow(aim: Node) -> void:
	if _owner_carrying:
		_owner_carrying = false
		mining_tool.set_stowed(false)
		return
	# Predict with the SAME validated target we send the server (it already passed the
	# line-of-sight + not-carried-by-another checks), so the optimistic stow can't flicker
	# into a brief "[E] Drop" when the grab is actually blocked (wall / another player's prop).
	if aim != null and aim.interact():
		_owner_carrying = true
		mining_tool.set_stowed(true)

# receive properties from the client, often the actions
func server_action_received(data: Dictionary) -> void:
	# Server authority: delegate to the PlayerServer role (only the dedicated server receives this).
	_role.server_action_received(data)
