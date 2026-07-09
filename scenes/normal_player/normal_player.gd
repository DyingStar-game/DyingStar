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
## no velocity) — used to throttle idle physics to every 10th tick.
var _idle_settled_ticks: int = 0

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
var _los_ray: RayCast3D = null

# Carry prompt, decided by the SERVER (it owns the collisions) and replicated to the owner:
# "" / "carry" / "drop" / "cargo" (cargo = dropping here loads it onto a truck). The client only
# displays it — it never computes reachability itself.
var _carry_prompt: String = ""
var _carry_prompt_timer: float = 0.0  # server-side throttle

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
		_spawn_wheel.option_selected.connect(_on_spawn_selected)

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
		_force_temp_sky_environment()
		# Apply the saved field of view, and follow live changes from the settings menu.
		camera.fov = SettingsManager.get_fov()
		SettingsManager.fov_changed.connect(_on_fov_changed)
		# Debug panels: follow live the settings-menu "Show debug panels" toggle.
		if not SettingsManager.show_debug_changed.is_connected(_on_show_debug_changed):
			SettingsManager.show_debug_changed.connect(_on_show_debug_changed)
		# our own name tag is never created (only remote players get one)
		astronaut.visible = false
		interact_label.hide()
		connect_area_detect()
		active = false

		await get_tree().create_timer(5).timeout

		update_last_basis()

		active = true

		# Initial visibility from the saved setting (default true — early alpha).
		_display_debug = SettingsManager.is_show_debug()
		display_debug.emit(_display_debug)

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

func _unhandled_input(event: InputEvent) -> void:
	if remote_player: return
	# Leave the seat we occupy (driver or passenger) with Y — but only if this seat's door is open
	# (open it first by looking at its handle). A seat with no door_id leaves directly.
	if _seat_vehicle_uuid != "" and event.is_action_pressed("exit"):
		if _seat_door_open(_seat_node):
			_leave_vehicle()
		return

	if _seat_is_driver and _seat_vehicle_uuid != "" and event.is_action_pressed("vehicle_reset"):
		# Reset the vehicle upright (server-authoritative; driver only).
		client_send_action_to_server({"action": "reset_vehicle", "target_uuid": _seat_vehicle_uuid})

	if _seat_is_driver and _seat_vehicle_uuid != "" and event.is_action_pressed("vehicle_lights"):
		# Toggle the vehicle head lights (server-authoritative; driver only).
		client_send_action_to_server({"action": "vehicle_lights", "target_uuid": _seat_vehicle_uuid})

	if event.is_action_pressed("toggle_flashlight"):
		# Toggle the player's torch — on foot AND while seated (driver or passenger), so it must
		# sit before the walk guard. By default it shares the L key with vehicle_lights, so one
		# press toggles both the torch and the head lights; rebind it to a separate key in
		# Settings > Controls to control the torch independently.
		client_send_action_to_server({"action": "toggle_flashlight"})

	# Capture mouse look even while seated (free look in a vehicle), before the walk guard.
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		mouse_motion = -event.relative * 0.001

	# Seated (driver/passenger): E open/closes a door by LOOKING at its handle. Must run BEFORE the
	# walk guard — seated players have active = false, so the on-foot action block below never runs.
	if _seat_vehicle_uuid != "" and event.is_action_pressed("action"):
		interact_ray.force_raycast_update()
		var seated_handle := _aimed_door_handle()
		if seated_handle != null:
			_toggle_door(seated_handle)
		return  # seated: E only operates doors, never carry

	if !active: return

	if event.is_action_pressed(JUMP):
		client_send_action_to_server({"action": JUMP})

	if event.is_action_pressed("toggle_tool"):
		if admin_cleanup_tool != null:
			admin_cleanup_tool.set_active(false)  # stow the admin tool when equipping the perforator
		mining_tool.toggle_equip()

	if event.is_action_pressed("action"):
		interact_ray.force_raycast_update()
		# On foot, looking at a door handle from a boarding zone: open/close that door (server-auth).
		# Priority over boarding, so aiming at the handle in the zone operates the door.
		var handle := _aimed_door_handle()
		if handle != null and is_instance_valid(_nearby_seat):
			_toggle_door(handle)
			return
		# Standing in a seat box: E boards — but only once the seat's gating door is open (open it
		# first by looking at the handle). A seat with no door_id boards directly.
		if is_instance_valid(_nearby_seat):
			if _seat_door_open(_nearby_seat):
				_enter_seat(_nearby_seat)
			return
		# Otherwise pick up / drop. Send the uuid of the carriable under OUR crosshair so the
		# server grabs exactly that one (its own ray can be slightly off and grab a neighbour).
		var aim := _aimed_carriable()
		var target_uuid := str(aim.uuid) if aim != null else ""
		client_send_action_to_server({"action": "action", "target_uuid": target_uuid})
		_predict_carry_stow(aim)

	if event.is_action_pressed("spawn_wheel"):
		if _spawn_wheel:
			_spawn_wheel.open([
				{"text": "Rocher", "submenu": [
					{"text": "S", "data": "rock"},
					{"text": "M", "data": "rock_medium"},
					{"text": "L", "data": "rock_large"},
				]},
				{"text": "Caisse", "submenu": [
					{"text": "50cm", "data": "box"},
					{"text": "Ares", "data": "palette_container"},
					{"text": "Palet", "data": "pallet_plate"},
					{"text": "Cube", "data": "pallet_crate"},
					{"text": "Benne", "data": "pallet_benne"},
					{"text": "Liquid", "data": "pallet_liquid"},
				]},
				{"text": "Dépôt", "data": "depot"},
				{"text": "Camion", "data": "truck"},
			])
	if event.is_action_released("spawn_wheel"):
		if _spawn_wheel:
			_spawn_wheel.confirm()

	if event.is_action_pressed("toggle_debug"):
		_display_debug = not _display_debug
		display_debug.emit(_display_debug)
		SettingsManager.set_show_debug(_display_debug)  # persist + keep the settings menu in sync

func server_set_input(input_dir: Vector2, newrotation: Vector3) -> void:
	input_from_server["input_direction"] = input_dir
	input_from_server["rotation"] = newrotation
	new_input_from_server = true

func _process(_delta: float) -> void:
	if remote_player:
		_interp.update(self, _delta)  # entity interpolation: glide between server updates
		_update_name_tag()
		return
	# Seated in a vehicle: ride the seat HERE, in sync with the vehicle's own _process
	# interpolation, so the camera stays glued to the (smoothly moving) cabin — no jitter/blur.
	if is_instance_valid(_seat_node):
		_ride_seat(_seat_node)
		# Seated: clear the on-foot prompts, but still let a driver/passenger close (or reopen) a door by
		# LOOKING at its handle — the handle rides the door now, so aiming works open or closed.
		interact_label.hide()
		var seated_handle := _aimed_door_handle()
		if seated_handle != null:
			interact_label.text = _door_prompt(seated_handle)
			interact_label.show()
		return
	# On foot: smooth our server-driven position (no client prediction yet) — position only, so
	# the mouse look stays immediate.
	_interp.update_position(self, _delta)
	if !active:
		interact_label.hide()
		return

	# Mining (aim, perforation, head sync) runs in the MiningTool; here we just
	# apply its effect on the local mouse look before moving the camera.
	mining_tool.update_local(_delta)
	if mining_tool.is_aiming:
		mouse_motion *= mining_tool.aim_sensitivity_factor
	if mining_tool.is_perforating:
		mouse_motion = Vector2.ZERO  # mouse frozen during perforation

	# Free the mouse + freeze the camera whenever the player isn't in direct control: focused on a
	# 3D screen, the spawn wheel, OR the pause menu is open. Otherwise capture the mouse and move the
	# camera. (Without the pause case, this would re-capture every frame and hide the menu cursor.)
	var ui_focus: bool = screen_interacting != null \
		or (_spawn_wheel != null and _spawn_wheel.visible) \
		or GameOrchestrator.current_state == GameOrchestrator.GameStates.PAUSE_MENU
	if ui_focus:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		mouse_motion = Vector2.ZERO
		# Turn the camera toward a 3D screen so it's centered in view.
		if screen_interacting and screen_position != camera.global_position:
			var look: Transform3D = camera.global_transform.looking_at(screen_position, up_direction)
			camera.global_transform = camera.global_transform.interpolate_with(look, 0.15)
	else:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		# Return the camera to the pivot's control after a screen interaction.
		camera.rotation = camera.rotation.lerp(Vector3.ZERO, 0.2)
		_handle_camera_motion()


	interact_label.hide()
	can_interact = false
	if interact_ray.is_colliding():
		var collider = interact_ray.get_collider()
		if collider:
			if collider.has_method("interact"):
				interact_label.text = collider.label
				interact_label.show()
				can_interact = true
				if Input.is_action_just_pressed("interact"):
					collider.interact(self)
					interact_label.hide()

	# Looking at a door handle, FROM the boarding zone (on foot) or while seated: E opens/closes it.
	# Priority over the seat prompt, so aiming at the handle in the zone shows the door action.
	if not interact_label.visible and (is_instance_valid(_nearby_seat) or _seat_vehicle_uuid != ""):
		var aimed_handle := _aimed_door_handle()
		if aimed_handle != null:
			interact_label.text = _door_prompt(aimed_handle)
			interact_label.show()

	# Standing in a seat box (on foot): board, or say it's taken / that the door must be opened first.
	if not interact_label.visible and is_instance_valid(_nearby_seat) and _seat_vehicle_uuid == "":
		if _seat_is_taken(_nearby_seat):
			interact_label.text = "Driver seat taken"
		elif not _seat_door_open(_nearby_seat):
			interact_label.text = "Open the door first (aim at the handle)"
		else:
			interact_label.text = "[E] Drive Seat" if _nearby_seat.is_driver_seat() else "[E] Passenger Seat"
		interact_label.show()

	# Carry/drop prompt (no other prompt showing). The SERVER decides it (it owns the collisions
	# and re-checks reachability + line of sight) and replicates _carry_prompt; we only display.
	if not interact_label.visible:
		if _carry_prompt == "drop":
			interact_label.text = "[E] Drop"
			interact_label.show()
		elif _carry_prompt == "cargo":
			interact_label.text = "[E] Cargo"  # dropping here loads it onto the truck (sticks)
			interact_label.show()
		elif _carry_prompt == "carry":
			interact_label.text = "[E] Carry"
			interact_label.show()


	if not OS.has_feature("dedicated_server"):
		var dir_vect = Vector3.ZERO
		var sprint = null

		#apply_parent_movement()

		if not direct_chat.can_write:
			dir_vect = Input.get_vector(MOVE_LEFT, MOVE_RIGHT, MOVE_FORWARD, MOVE_BACK)
			sprint = Input.is_action_pressed(SPRINT)

		if dir_vect:
			input_direction = dir_vect
		else:
			input_direction = Vector2.ZERO

		# send move_direction
		# if input_direction != client_last_input_direction or global_rotation != client_last_global_rotation:
		# 	client_last_input_direction = input_direction
		# 	client_last_global_rotation = global_rotation
		# 	emit_signal("hs_client_action_move", input_direction, global_rotation)
		update_last_basis()

		labelx.text = str("%0.2f" % global_position[0])
		labely.text = str("%0.2f" % global_position[1])
		labelz.text = str("%0.2f" % global_position[2])

## Seat the player so its OWN camera lands on the vehicle's cab-eye point (faces forward).
## Owner: send our driving input to the server (only when it changes; the server holds it).
func _send_drive_input() -> void:
	var throttle: float = Input.get_axis("move_back", "move_forward")
	var steer: float = Input.get_axis("move_right", "move_left")
	var braking: bool = Input.is_action_pressed("brake")
	if throttle == _last_throttle and steer == _last_steer and braking == _last_brake:
		return
	_last_throttle = throttle
	_last_steer = steer
	_last_brake = braking
	client_send_action_to_server({
		"action": "vehicle_input",
		"target_uuid": _seat_vehicle_uuid,
		"throttle": throttle,
		"steer": steer,
		"brake": braking,
	})

## Driver: a long press on the brake key at low speed toggles the hand brake (once per hold).
func _update_handbrake_input(delta: float) -> void:
	if not Input.is_action_pressed("brake"):
		_space_held_time = 0.0
		_handbrake_sent = false
		return
	_space_held_time += delta
	if _handbrake_sent or _space_held_time < HANDBRAKE_HOLD_SECS:
		return
	var speed_kmh: float = 999.0
	if is_instance_valid(_seat_vehicle_node) and _seat_vehicle_node.has_method("get_display_speed_kmh"):
		speed_kmh = _seat_vehicle_node.get_display_speed_kmh()
	if speed_kmh > HANDBRAKE_MAX_KMH:
		return
	_handbrake_sent = true
	client_send_action_to_server({"action": "vehicle_handbrake", "target_uuid": _seat_vehicle_uuid})

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

## True when the seat is occupied (E won't work). Only the DRIVER seat's occupancy is
## replicated (via the vehicle's pilot_uuid); a passenger seat reads as free for now.
func _seat_is_taken(seat: Node) -> bool:
	if seat == null or not seat.is_driver_seat():
		return false
	var veh: Node = seat.vehicle() if seat.has_method("vehicle") else null
	return veh != null and "pilot_uuid" in veh and str(veh.pilot_uuid) != ""

## Take the seat we are standing in: tell the server, lock walking, start riding locally.
func _enter_seat(seat: Node) -> void:
	var veh: Node = seat.vehicle()
	if veh == null or not ("uuid" in veh):
		return
	if _seat_is_taken(seat):
		return  # driver seat already occupied (server-replicated) — don't enter optimistically
	_seat_node = seat
	_seat_vehicle_node = veh
	_seat_vehicle_uuid = str(veh.uuid)
	_seat_is_driver = seat.is_driver_seat()
	client_send_action_to_server({
		"action": "enter_vehicle",
		"target_uuid": _seat_vehicle_uuid,
		"seat": seat.name,
	})
	active = false  # lock walking while seated
	set_seated(true)
	# Ride by transform inheritance: parent to the vehicle so we move WITH it (no jitter). The
	# vehicle stays server-authoritative; this is the local camera ride.
	if veh is Node3D and get_parent() != veh:
		reparent(veh)
		net_reset_interp()
	if _seat_is_driver and veh.has_method("set_driver_hud"):
		veh.set_driver_hud(true)

## Leave the seat we occupy (driver or passenger): tell the server, walk again, un-parent back into
## the world, and drop the driver HUD. Triggered by Y (exit) — see _unhandled_input.
func _leave_vehicle() -> void:
	client_send_action_to_server({"action": "exit_vehicle", "target_uuid": _seat_vehicle_uuid})
	active = true  # walking again
	set_seated(false)
	camera_pivot.rotation = Vector3.ZERO  # restore walking look (yaw goes back on the body)
	# Un-parent from the vehicle, back into the world (the server repositions us beside it).
	if is_instance_valid(_seat_vehicle_node) and get_parent() == _seat_vehicle_node:
		var world: Node = _seat_vehicle_node.get_parent()
		if world != null:
			reparent(world)
			net_reset_interp()
	if _seat_is_driver and is_instance_valid(_seat_vehicle_node) and _seat_vehicle_node.has_method("set_driver_hud"):
		_seat_vehicle_node.set_driver_hud(false)
	_seat_vehicle_uuid = ""
	_seat_vehicle_node = null
	_seat_node = null
	_seat_is_driver = false

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

func _physics_process(delta: float) -> void:
	if remote_player: return
	if OS.has_feature("dedicated_server"):
		_server_update_carried_item()
		_server_update_carry_prompt(delta)
		if piloting and is_instance_valid(_seat_node):
			# Seated in a vehicle: ride its seat. Server-authoritative; the emitted
			# position replicates so the player follows the vehicle (camera rides too).
			_ride_seat(_seat_node)
			new_input_from_server = false
			var seat_p: Vector3 = snapped(position, Vector3(0.001, 0.001, 0.001))
			var seat_r: Vector3 = snapped(global_rotation, Vector3(0.0001, 0.0001, 0.0001))
			emit_signal("hs_server_move", client_uuid, seat_p, seat_r, null, is_parented)
			return
		if new_input_from_server:
			input_direction = input_from_server["input_direction"]
			global_rotation = input_from_server["rotation"]
			if piloting:
				input_direction = Vector2.ZERO  # seated in a vehicle: no walking

		# Server-side "sleep" for settled players — the CharacterBody analogue
		# of RigidBody sleeping. An idle player standing on the floor does not
		# need 60 physics ticks/s: once quasi-still for 0.5 s, run the full
		# move_and_slide only every 10th tick (6 Hz keeps the floor contact
		# honest — if the chunk under the player unloads, the fall starts
		# within 10 ticks). Any client packet, input, or residual velocity
		# resets the counter instantly. With N players/vehicles idle around a
		# base this removes ~90% of their per-tick physics cost and, combined
		# with the position dedup in _on_player_move, all their network
		# traffic.
		if not new_input_from_server and input_direction == Vector2.ZERO \
				and is_on_floor() and velocity.length_squared() < 0.0001:
			_idle_settled_ticks += 1
			if _idle_settled_ticks > 30 and (_idle_settled_ticks % 10) != 0:
				return
		else:
			_idle_settled_ticks = 0

		var sprint = null
		# print("gravity parents:", gravity_parents.size())
		var parent_gravity_area: Area3D = gravity_parents.back() if not gravity_parents.is_empty() else null
		# print("gravity parents after:", gravity_parents.size())

		if parent_gravity_area:
			if parent_gravity_area.gravity_point:
				up_direction = parent_gravity_area.global_position.direction_to(global_position)
			else:
				up_direction = parent_gravity_area.global_basis.y

			gravity = _compute_gravity(parent_gravity_area)
			motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
		else:
			# 0g movement
			gravity = 0.0
			camera_pivot.rotation.x = 0
			motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
			var dir = Vector3(input_direction.x, 0, input_direction.y)

			# TODO sometimes the value is null on server side, not know why :/
			player_thruster_force = 10
			velocity += global_basis * dir * player_thruster_force * delta
			velocity *= 0.98

		var move_direction = (global_transform.basis * Vector3(input_direction.x, 0, input_direction.y)).normalized()

		var speed = sprint_speed if sprint else walk_speed
		if mining_tool.is_aiming:
			speed *= mining_tool.aim_speed_factor  # slowed down in aim mode
		if mining_tool.is_perforating:
			speed = 0.0  # frozen during perforation
		if hands_item != null:
			speed *= carry_speed_factor  # carrying an ore slows you down (issue #124)

		if is_on_floor():
			if input_direction:
				velocity = move_direction * speed
			else:
				velocity = velocity.move_toward(Vector3.ZERO, speed)
		else:
			# "air" movement
			if input_direction:
				velocity += move_direction * speed * delta


		if is_on_floor() and is_jumping:
			velocity += up_direction * jump_height * gravity
			is_jumping = false
		# Add the gravity — ALWAYS, including while standing on the floor. The
		# floor contact absorbs it (move_and_slide cancels the into-floor
		# component) and keeps the capsule firmly pressed onto the terrain
		# trimesh so is_on_floor() stays true. Gating this on
		# "not is_on_floor()" made the contact flicker when idle: the idle
		# branch zeroes velocity → a zero-motion slide loses the floor → next
		# tick one dose of gravity sinks the body ~9 mm → depenetration pushes
		# it back → permanent ~1 cm "dancing", broadcast to every client at
		# full tick rate (the position changes > the 1 mm dedup snap).
		else:
			velocity -= up_direction * gravity * 2.0 * delta
			is_jumping = false

		# Cap fall speed to avoid tunneling through ConcavePolygonShape3D
		# terrain.  At 30 Hz physics with ~50 m chunk-vertex spacing,
		# velocities above ~1500 m/s could cross multiple triangles per
		# frame.  60 m/s is a generous "skydiver" terminal velocity that
		# leaves a wide safety margin while still feeling like real gravity.
		var _terminal_velocity: float = 60.0
		if velocity.length() > _terminal_velocity:
			velocity = velocity.normalized() * _terminal_velocity

		move_and_slide()

		# Safety net: a CharacterBody can tunnel through the thin trimesh terrain
		# on a fast fall (move_and_slide has no CCD). Catch it if it ends up
		# clearly below the surface so it can't fall to the planet centre.
		if parent_gravity_area and parent_gravity_area.gravity_point \
				and parent_gravity_area.name == "PlanetGravity":
			_catch_if_below_surface(parent_gravity_area)


		update_last_basis()

		new_input_from_server = false

		emit_signal(
			"hs_server_move",
			client_uuid,
			# stepify tu prevent floating points with too many chars after coma
			snapped(position, Vector3(0.001, 0.001, 0.001)),
			snapped(global_rotation, Vector3(0.0001, 0.0001, 0.0001)),
			null,
			is_parented
		)

	else:
		# player part
		if is_instance_valid(_seat_node):
			# Seated: the camera ride is done in _process (synced with the vehicle interpolation);
			# here we only relay drive input (driver) and skip walking.
			if _seat_is_driver:
				_send_drive_input()
				_update_handbrake_input(delta)
			return
		if !active: return

		var dir_vect = Vector3.ZERO
		var sprint = null

		#apply_parent_movement()

		if not direct_chat.can_write:
			dir_vect = Input.get_vector(MOVE_LEFT, MOVE_RIGHT, MOVE_FORWARD, MOVE_BACK)
			sprint = Input.is_action_pressed(SPRINT)

		if dir_vect:
			input_direction = dir_vect
		else:
			input_direction = Vector2.ZERO
		# send move_direction
		var short_rotation = snapped(global_rotation, Vector3(0.0001, 0.0001, 0.0001))
		if input_direction != client_last_input_direction or short_rotation != client_last_global_rotation:
			client_last_input_direction = input_direction
			client_last_global_rotation = short_rotation
			emit_signal("hs_client_action_move", input_direction, short_rotation)
		update_last_basis()

		labelx.text = str("%0.2f" % global_position[0])
		labely.text = str("%0.2f" % global_position[1])
		labelz.text = str("%0.2f" % global_position[2])

func should_listen_input() -> bool:
	return not (direct_chat.is_shown || MenuConfig.is_shown)

func _handle_camera_motion():
	var parent_gravity_area: Area3D = gravity_parents.back() if not gravity_parents.is_empty() else null

	if parent_gravity_area:
		_no_gravity_time = 0.0
		if parent_gravity_area.gravity_point:
			up_direction = parent_gravity_area.global_position.direction_to(global_position)
		else:
			up_direction = parent_gravity_area.global_basis.y

		gravity = _compute_gravity(parent_gravity_area)
		orient_player()
		global_basis = global_basis.rotated(global_basis.y, mouse_motion.x * camera_sensitivity)
		camera_pivot.rotate_object_local(Vector3.RIGHT, mouse_motion.y  * camera_sensitivity)
		camera_pivot.rotation_degrees.x = clamp(camera_pivot.rotation_degrees.x, -80, 80)
	else:
		# No gravity area. Ignore a brief gap (e.g. a reparent leaving a spawn apartment) — only treat
		# it as real 0g after ZERO_G_GRACE, so the camera pitch survives the transition.
		_no_gravity_time += get_process_delta_time()
		if _no_gravity_time >= ZERO_G_GRACE:
			# 0g movement
			gravity = 0.0
			camera_pivot.rotation.x = 0
			rotate_object_local(Vector3.UP, mouse_motion.x  * camera_sensitivity)
			rotate_object_local(Vector3.RIGHT, mouse_motion.y  * camera_sensitivity)

	# Replicate the camera pitch ("head") to the server so others see where we look and
	# the server can aim our interaction ray + place a carried item (tech-debt A / #124).
	var head_q := snappedf(camera_pivot.rotation.x, 0.02)
	if head_q != _last_head_sent:
		_last_head_sent = head_q
		client_send_action_to_server({"action": "update_property", "head": head_q})

	mouse_motion = Vector2.ZERO

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
	var local_world: Vector3 = global_position - planet.global_position
	if local_world.length_squared() < 1.0:
		return
	var planet_basis: Basis = planet.global_transform.basis
	var local_body: Vector3 = planet_basis.inverse() * local_world
	var dir: Vector3 = local_body.normalized()
	var player_dist: float = local_body.length()
	var surface_dist: float = pdata.crack_aware_surface_dist(dir)
	if player_dist >= surface_dist - _SURFACE_CATCH_MARGIN:
		return  # at/near or above the surface — the collision handles it
	global_position = planet.global_position + planet_basis * (dir * surface_dist)
	var up_world: Vector3 = (planet_basis * dir).normalized()
	var radial: float = velocity.dot(up_world)
	if radial < 0.0:
		velocity -= up_world * radial


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

## TEMPORARY (until the planet sun/atmosphere system is fixed): build a physical-sky environment
## directly on the player camera. A Camera3D's own environment overrides any rival WorldEnvironment
## (the scene's WorldEnvironment doesn't apply in-game here -> black sky), so this is what reliably
## shows the sky to every player. The PhysicalSky reacts to the DirectionalLight, so the day/night
## sun tint applies. Keep these values in sync with the WorldEnvironment in sandbox_capital.tscn.
## Remove this whole helper once the real sun/atmosphere system is in place.
func _force_temp_sky_environment() -> void:
	var sky_material := PhysicalSkyMaterial.new()
	sky_material.rayleigh_coefficient = 2.5
	sky_material.mie_coefficient = 0.02
	sky_material.mie_eccentricity = 0.85
	sky_material.turbidity = 12.0
	sky_material.sun_disk_scale = 3.0
	sky_material.ground_color = Color(0.35, 0.28, 0.22)
	sky_material.energy_multiplier = 1.2
	var sky := Sky.new()
	sky.sky_material = sky_material
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.glow_enabled = true
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.002
	camera.environment = env

## Live camera FOV update from the settings menu (local player only).
func _on_fov_changed(fov: float) -> void:
	camera.fov = fov

## Live update from the settings menu "Show debug panels" toggle (kept in sync with the toggle_debug key).
func _on_show_debug_changed(on: bool) -> void:
	_display_debug = on
	display_debug.emit(on)

# Dev spawn wheel selection -> spawn the chosen prop in front of the player.
func _on_spawn_selected(data) -> void:
	if SPAWN_PROPS.has(data):
		var p: Dictionary = SPAWN_PROPS[data]
		spawn_box(p["scene"], p["type"], p["z"], p["y"])
	elif data == "depot":
		_spawn_depot()
	elif data == "truck":
		_spawn_truck()

# Spawn a networked truck (server-authoritative vehicle prop) in front of the player. The
# server simulates its physics and replicates it to every client (B1 vehicle networking).
func _spawn_truck() -> void:
	var spawn_pos: Vector3 = position + (-global_basis.z * 8.0) + global_basis.y * 1.0
	var parent = get_parent()
	# Robust to the scene layout: any parent without a uuid (SystemSandbox, a grouping node) = "".
	var parentuuid = str(parent.uuid) if "uuid" in parent else ""
	client_send_action_to_server({
		"action": "spawn_vehicle",
		"position": {"x": spawn_pos.x, "y": spawn_pos.y, "z": spawn_pos.z},
		"parent_id": parentuuid,
	})

# LOCAL DEV (do not commit): spawn a mining depot a few meters in front of the player.
func _spawn_depot() -> void:
	var spawn_pos: Vector3 = position + (-global_basis.z * 10.0)
	var parent = get_parent()
	# Robust to the scene layout: any parent without a uuid (SystemSandbox, a grouping node) = "".
	var parentuuid = str(parent.uuid) if "uuid" in parent else ""
	emit_signal(
		"client_action_requested",
		{
			"action": "spawn",
			"entity": "mining_depot",
			"position": {"x": spawn_pos.x, "y": spawn_pos.y, "z": spawn_pos.z},
			"scenename": "scenes/structures/mining_depot.tscn",
			"parent_id": parentuuid,
		}
	)

func spawn_box(_boxscene: String, _type: String, _coeffz: float, _coeffy: float):
	# LOCAL DEV (do not commit): re-enabled to spawn mining rocks for testing.
	var item_spawn_position: Vector3 = position + (-global_basis.z * _coeffz) + global_basis.y * _coeffy
	var parent = get_parent()
	# Robust to the scene layout: any parent without a uuid (SystemSandbox, a grouping node) = "".
	var parentuuid = str(parent.uuid) if "uuid" in parent else ""
	emit_signal(
		"client_action_requested",
		{
			"action": "spawn",
			"entity": _type,
			"position": {
				"x": item_spawn_position[0],
				"y": item_spawn_position[1],
				"z": item_spawn_position[2]
			},
			"scenename": "scenes/props/" + _boxscene + ".tscn",
			"parent_id": parentuuid,
		}
	)
	# var item_spawn_position: Vector3 = position + (-global_basis.z * coeffz) + global_basis.y * coeffy
	# # parent is for example the planet
	# var parent = get_parent();
	# var parentuuid = ""
	# if parent.name == "SystemSandbox":
	# 	parentuuid = ""
	# else:
	# 	parentuuid = parent.uuid

	# emit_signal(
	# 	"client_action_requested",
	# 	{
	# 		"action": "spawn",
	# 		"entity": type,
	# 		"position": {
	# 			"x": item_spawn_position[0],
	# 			"y": item_spawn_position[1],
	# 			"z": item_spawn_position[2]
	# 		},
	# 		"scenename": "scenes/props/" + boxscene + ".tscn",
	# 		"parent_id": parentuuid,
	# 	}
	# )

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

## Find a spawned mining rock by its uuid (server-side).
## Walk up from a raycast hit to the vehicle node it belongs to (group "vehicle"), else null.
func _find_vehicle(target_uuid: String) -> Node:
	if target_uuid == "":
		return null
	for v in get_tree().get_nodes_in_group("vehicle"):
		if "uuid" in v and str(v.uuid) == target_uuid:
			return v
	return null

## Which truck bed should swallow a crate dropped at this world point: any truck whose designer
## loading zone contains it. Same rule whether we stand in the bed or reach over from outside — the
## zone (not the player's position) decides whether loading is allowed.
func _cargo_bed_for_drop(world_point: Vector3) -> Vehicle:
	for v in get_tree().get_nodes_in_group("vehicle"):
		if v is Vehicle and v.is_point_in_loading_zone(world_point):
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

## The vehicle door handle under the crosshair (a VehicleDoorHandle Area3D on the interact layer),
## or null. Look-at detection; the actual open/close is server-authoritative (sent on E).
func _aimed_door_handle() -> VehicleDoorHandle:
	if not interact_ray.is_colliding():
		return null
	var hit = interact_ray.get_collider()
	var handle := hit as VehicleDoorHandle
	if handle == null:
		return null
	# Only the box on our current side counts: outdoor on foot, indoor when seated in this vehicle.
	# Aiming at the far-side box (the one you can't reach from where you are) is ignored.
	if not _door_side_matches(handle):
		return null
	return handle

## True when the handle box under the crosshair is on the player's side (outdoor on foot, indoor when
## seated in that vehicle). "" side (no boxes assigned) always matches, so an un-configured handle works.
func _door_side_matches(handle: VehicleDoorHandle) -> bool:
	var side := handle.aimed_side(interact_ray.get_collision_point())
	if side == "":
		return true
	var veh = handle.vehicle()
	var inside: bool = veh != null and "uuid" in veh and _seat_vehicle_uuid == str(veh.uuid)
	return side == ("indoor" if inside else "outdoor")

## Tell the server to open/close the door this handle drives (server-authoritative, replicated back).
func _toggle_door(handle: VehicleDoorHandle) -> void:
	var veh = handle.vehicle()
	if veh == null:
		return
	client_send_action_to_server({
		"action": "vehicle_door",
		"target_uuid": str(veh.uuid),
		"door_id": handle.door_id,
		"side": handle.aimed_side(interact_ray.get_collision_point()),
	})

## Prompt for a door handle under the crosshair: close it if open, else open it.
func _door_prompt(handle: VehicleDoorHandle) -> String:
	var veh = handle.vehicle()
	var is_open: bool = veh != null and veh.has_method("is_door_open") and veh.is_door_open(handle.door_id)
	return "[E] Close door" if is_open else "[E] Open door"

## True if a seat may be boarded right now: it has no gating door, or its door_id is currently open.
## Lets a vehicle require "open the door first" before E enters (the door is opened via its handle).
func _seat_door_open(seat) -> bool:
	if seat == null or not ("door_id" in seat) or str(seat.door_id) == "":
		return true
	var veh = seat.vehicle()
	if veh == null or not veh.has_method("is_door_open"):
		return true
	return veh.is_door_open(str(seat.door_id))

## Primitive: true if a MASK_OBSTACLE ray from the eye to `target` (a world point) is cut by a solid
## before reaching it. `exceptions` are solids to ignore besides ourselves. Used for look-at boxes that
## sit in open air (door handles): the box on the near side is clear, the one behind the body is not.
func _line_of_sight_blocked(target: Vector3, exceptions: Array) -> bool:
	_ensure_los_ray()
	# top_level → target_position is a world-space delta (no parent transform to fight).
	_los_ray.global_position = interact_ray.global_position
	_los_ray.target_position = target - _los_ray.global_position
	_los_ray.clear_exceptions()
	_los_ray.add_exception(self)
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
		var hit_dist: float = _los_ray.global_position.distance_to((c as Node3D).global_position)
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
		var inside: bool = veh != null and veh.has_method("is_occupied_by") and veh.is_occupied_by(self)
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
	_los_ray.global_position = interact_ray.global_position
	var to_target: Vector3 = target.global_position - _los_ray.global_position
	# Aim a touch past the centre so a thin/small target is still crossed by the ray.
	_los_ray.target_position = to_target * 1.05
	_los_ray.clear_exceptions()
	_los_ray.add_exception(self)
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
		var hit_dist: float = _los_ray.global_position.distance_to((c as Node3D).global_position)
		return hit_dist > target_dist
	return false

## True if a solid wall stands between the eye and the carriable `prop`. Thin wrapper over `_can_see`
## for the carry call sites; tiny ore pieces detect unreliably, so we don't gate them on sight.
func _is_blocked_by_geometry(prop: Node) -> bool:
	if prop is Node3D and "type_name" in prop and prop.type_name == "miningrock":
		return false
	return not _can_see(prop)

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

## Server: keep the carried item floating in front of the body (yaw only, no camera
## pitch), held by the middle of its geometry so it sits centered. A cut piece keeps the
## original rock pivot, so we offset by its geometry center (deterministic -> clients
## match without extra sync). (#124)
func _server_update_carried_item() -> void:
	if hands_item == null:
		return
	# Body-relative spot (head height + front) WITHOUT the camera pitch: a carried object
	# follows the body yaw but not the up/down look (issue #124).
	var carry_point: Vector3 = camera_pivot.position + carry_offset
	var center: Vector3 = Vector3.ZERO
	if hands_item.has_method("get_center_offset"):
		center = hands_item.get_center_offset()
	hands_item.position = carry_point - hands_item.basis * center

## Server-authoritative carry prompt: the server (which owns the collisions) decides what E
## will do from the player's replicated aim, and replicates "carry"/"drop"/"" to the owner —
## the client just displays it. Throttled so it's cheap (one ray per player, not per object).
func _server_update_carry_prompt(delta: float) -> void:
	_carry_prompt_timer -= delta
	if _carry_prompt_timer > 0.0:
		return
	_carry_prompt_timer = 0.1
	var state := _compute_carry_prompt()
	if state != _carry_prompt:
		_carry_prompt = state
		server_send_properties_to_client({"carry_prompt": state})

## What E would do right now (server side): if we hold something, "cargo" when the drop would load
## it onto a truck (it sticks), else "drop"; if our hands are empty, "carry" when we aim at a
## grabbable prop that is reachable (not carried by another, clear line of sight).
func _compute_carry_prompt() -> String:
	if hands_item != null:
		if _cargo_bed_for_drop(hands_item.global_position) != null:
			return "cargo"  # dropping here loads it into the bed (sticks)
		return "drop"
	interact_ray.force_raycast_update()
	var prop := _aimed_carriable()
	if prop != null and prop.has_method("interact") and prop.interact(self) \
			and not _is_blocked_by_geometry(prop):
		return "carry"
	return ""

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
	match data["action"]:
		JUMP:
			is_jumping = true
		"toggle_flashlight":
			# Server-authoritative: flip the state and replicate it so the owner AND other players
			# see the torch (replicated as a state, not the action — a missed event can't desync it).
			flashlight.visible = not flashlight.visible
			server_send_properties_to_client({"flashlight": flashlight.visible})
		"screen_state":
			# A 3D screen (mining depot) button was pressed: route it to that screen.
			if screen_interacting and screen_interacting.has_method("update_screen"):
				screen_interacting.update_screen(data)
		"update_property":
			# Generic player-property update (tech-debt A): apply the authoritative
			# side-effects we know about, then replicate every property to nearby
			# clients. Replaces the per-property equip_tool/set_head/set_perforating.
			var props: Dictionary = data.duplicate()
			props.erase("action")
			if props.has("tools"):
				mining_tool.server_set_tool(str(props["tools"]))
			if props.has("head"):
				# Apply on the server too so the interaction ray + carried item follow
				# the gaze (planet only; in 0g the body orientation is used instead).
				camera_pivot.rotation.x = float(props["head"])
			server_send_properties_to_client(props)
		"perforate_rock":
			# Authoritative fracture: cut the targeted rock along the aimed fault.
			var rock := _find_mining_rock(str(data.get("uuid", "")))
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
				# Free the node (removes its collision body) AND tell Horizon to drop it from the
				# GORC + database. Both are needed: queue_free alone may not replicate the delete
				# (e.g. the depot), and the GORC delete alone leaves a collision ghost.
				var prop := _find_deletable_prop(del_uuid)
				if prop != null and is_instance_valid(prop):
					# Held by this server: free it; _exit_tree replicates the delete to
					# Horizon (GORC) and the database, like a rock dropped into a depot.
					print("🗑️ Admin delete: freeing local node %s %s" % [del_type, del_uuid])
					_reparent_children_of_prop(prop) # reparent all children to the paremtn of this scene that will be deleted
					prop.queue_free()
				if NetworkOrchestrator.network_agent.has_method("_on_prop_delete"):
					# Not held locally (e.g. loaded from the database): tell Horizon directly
					# so it leaves the GORC and the database anyway.
					print("🗑️ Admin delete: forwarding to Horizon %s %s" % [del_type, del_uuid])
					NetworkOrchestrator.network_agent._on_prop_delete(del_uuid, del_type)
		"spawn_vehicle":
			# Server-authoritative vehicle: spawn it in Horizon (all clients) AND locally
			# on this game server (physics body that simulates + replicates). B1 networking.
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
			var veh := _find_vehicle(str(data.get("target_uuid", "")))
			if veh != null and veh.has_method("server_enter"):
				veh.server_enter(self, str(data.get("seat", "")))
		"exit_vehicle":
			var veh_out := _find_vehicle(str(data.get("target_uuid", "")))
			if veh_out != null and veh_out.has_method("server_exit"):
				veh_out.server_exit(self)
		"vehicle_input":
			var veh_in := _find_vehicle(str(data.get("target_uuid", "")))
			if veh_in != null and veh_in._pilot == self and veh_in.has_method("set_drive_input"):
				veh_in.set_drive_input(
					float(data.get("throttle", 0.0)),
					float(data.get("steer", 0.0)),
					bool(data.get("brake", false)))
		"reset_vehicle":
			var veh_r := _find_vehicle(str(data.get("target_uuid", "")))
			if veh_r != null and veh_r._pilot == self and veh_r.has_method("reset_upright"):
				veh_r.reset_upright()
		"vehicle_handbrake":
			var veh_h := _find_vehicle(str(data.get("target_uuid", "")))
			if veh_h != null and veh_h._pilot == self and veh_h.has_method("toggle_handbrake"):
				veh_h.toggle_handbrake()
		"vehicle_lights":
			var veh_l := _find_vehicle(str(data.get("target_uuid", "")))
			if veh_l != null and veh_l._pilot == self and veh_l.has_method("toggle_headlights"):
				veh_l.toggle_headlights()
		"vehicle_door":
			# A door handle is operated on foot by anyone nearby - NOT gated on the driver.
			# Server-authoritative so a client can't forge opening a door it can't use: (1) the box it
			# aimed at must match the player's side (outdoor on foot, indoor when seated in this vehicle),
			# and (2) that box must have a clear sightline (see _can_see). Both run on the server.
			var veh_d := _find_vehicle(str(data.get("target_uuid", "")))
			if veh_d != null and veh_d.has_method("server_toggle_door"):
				var handle_d: Node3D = veh_d.get_door_handle(str(data.get("door_id", ""))) \
						if veh_d.has_method("get_door_handle") else null
				var inside_d: bool = veh_d.has_method("is_occupied_by") and veh_d.is_occupied_by(self)
				var claimed_side: String = str(data.get("side", ""))
				var side_ok: bool = claimed_side == "" or claimed_side == ("indoor" if inside_d else "outdoor")
				if side_ok and (handle_d == null or _can_see(handle_d)):
					veh_d.server_toggle_door(str(data.get("door_id", "")))
		"action":
			print("action key pressed by player")
			if hands_item != null:
				# we have something in hands, so release it
				print("player has an item in hands, dropping it")
				# Generic: let the object know it is no longer carried (issue #124).
				if hands_item.has_method("set_carried"):
					hands_item.set_carried(false)
				hands_item.remove_collision_exception_with(self)  # it can collide with us again
				_carry_ignore_vehicles(hands_item, false)  # restore normal collision with vehicles
				# Drop INTO a bed -> load it onto that truck (the bed no longer polls for cargo). We
				# load it if we are standing in the bed, OR if we drop it from outside but it lands
				# inside a nearby truck's cargo bay (e.g. reaching over the side wall).
				if hands_item is RigidBody3D:
					var bed := _cargo_bed_for_drop(hands_item.global_position)
					if bed != null:
						bed.lock_dropped_cargo(hands_item)
						hands_item = null
						server_send_properties_to_client({"carrying": false})
						return
				var drop_parent := get_parent()
				hands_item.server_parent_change(drop_parent)
				hands_item.freeze = false
				# Robust to the scene layout: a parent without a uuid (grouping/test-zone node) = "".
				hands_item.send_properties_to_client(str(drop_parent.uuid) if "uuid" in drop_parent else "")
				hands_item = null
				# Stop carrying on all clients (perforator comes back) (issue #124).
				server_send_properties_to_client({"carrying": false})
			else:
				# Pick up the carriable the CLIENT aimed at: it sends the uuid under its
				# crosshair, so we grab exactly that one. (Our own server ray can be a hair
				# off — pitch is throttled/lagged — and would grab the neighbour.) (#124)
				var parent_node := _find_carriable(str(data.get("target_uuid", "")))
				var picked_up := false
				# Server-authoritative: same gate as the client — grabbable (not already carried)
				# AND a clear line of sight, so a thin wall can't be exploited to grab through it.
				var can_grab: bool = parent_node != null and parent_node.has_method("interact") \
						and parent_node.interact(self) and not _is_blocked_by_geometry(parent_node)
				if can_grab:
					# If it's secured in a vehicle bed, take it out of the load first (retrieval).
					var prev_parent := parent_node.get_parent()
					if prev_parent is Vehicle and prev_parent.has_method("release_cargo"):
						prev_parent.release_cargo(parent_node)
					parent_node.freeze = true
					parent_node.add_collision_exception_with(self)  # solid to others, not the carrier
					_carry_ignore_vehicles(parent_node, true)  # a held (frozen) crate must not shove a truck
					# Make sure its replication is active: a crate that sat in a bed may have had its
					# _physics_process paused, which would stop PropNet from replicating a later drop.
					parent_node.set_physics_process(true)
					parent_node.server_parent_change(self)
					parent_node.position = Vector3(0.0, 1.0, -1.0)
					#  send reparent to client
					parent_node.send_properties_to_client(self.client_uuid)
					hands_item = parent_node
					picked_up = true
					# Generic: mark carriables (e.g. a fault-less ore) as taken so
					# nobody else can grab them while in hands (issue #124).
					if parent_node.has_method("set_carried"):
						parent_node.set_carried(true)
					# Mark as carrying on all clients (perforator stows) (issue #124).
					server_send_properties_to_client({"carrying": true})
				if not picked_up:
					# Grabbed nothing: tell the owner to undo its optimistic stow (issue #124).
					server_send_properties_to_client({"carrying": false})

			# TODO
			# synchro head/camera

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
