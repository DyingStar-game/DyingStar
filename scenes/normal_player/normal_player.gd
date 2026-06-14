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
const CROUCH: String = "crouch"
const SPRINT: String = "sprint"
const PAUSE: String = "pause"

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

# Hand brake: a long press on the brake (Space) at low speed toggles the vehicle's hand brake.
const HANDBRAKE_HOLD_SECS: float = 0.4
const HANDBRAKE_MAX_KMH: float = 3.0

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

# Last camera pitch ("head" player property) sent to the server, throttled.
var _last_head_sent: float = INF
var _interp := NetInterpolator.new()  # smooths a REMOTE player's replicated movement
# Owner-local prediction of "am I carrying?", to stow/unstow the perforator immediately
# (the server broadcasts the stow to OTHER players; the owner doesn't echo to itself).
var _owner_carrying: bool = false

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
# The VehicleSeat box the local player stands in (set by VehicleSeat); E takes that seat.
var _nearby_seat: Node = null
var _last_throttle: float = INF  # last drive input sent (to send only on change)
var _last_steer: float = INF
var _last_brake: bool = false
var _space_held_time: float = 0.0  # driver: how long the brake (Space) has been held
var _handbrake_sent: bool = false  # driver: hand brake toggle already fired for this hold
var _seated_saved: bool = false
var _saved_collision_layer: int = 1
var _saved_collision_mask: int = 1


@onready var camera = $CameraPivot/Camera3D

@onready var labelx: Label = $UserInterface/Debug/LabelXValue
@onready var labely: Label = $UserInterface/Debug/LabelYValue
@onready var labelz: Label = $UserInterface/Debug/LabelZValue
@onready var label_player_name: Label3D = %LabelPlayerName
@onready var label_server_name: Label3D = %Labelserver_name
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
		$CameraPivot.visible = false

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

	if remote_player:
		camera.current = false
		set_player_name(name)
		return

	if not OS.has_feature("dedicated_server"):
		$UserInterface/LoadingScreen.show()

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
		# hide player name label for me only
		label_player_name.visible = false
		label_server_name.visible = false
		astronaut.visible = false
		interact_label.hide()
		connect_area_detect()
		active = false

		await get_tree().create_timer(5).timeout

		update_last_basis()

		active = true

		display_debug.emit(true)
		_display_debug = true

		$UserInterface/LoadingScreen.hide()
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
	if event.is_action_pressed("exit") and _seat_vehicle_uuid != "":
		# Leave the seat we occupy (driver or passenger).
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

	if _seat_is_driver and _seat_vehicle_uuid != "" and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		# Reset the vehicle upright (server-authoritative; driver only).
		client_send_action_to_server({"action": "reset_vehicle", "target_uuid": _seat_vehicle_uuid})

	# Capture mouse look even while seated (free look in a vehicle), before the walk guard.
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		mouse_motion = -event.relative * 0.001

	if !active: return

	if event.is_action_pressed(JUMP):
		client_send_action_to_server({"action": JUMP})

	if event.is_action_pressed("toggle_flashlight"):
		client_send_action_to_server({"action": "toggle_flashlight"})
		# flashlight.visible = not flashlight.visible

	if event.is_action_pressed("toggle_tool"):
		if admin_cleanup_tool != null:
			admin_cleanup_tool.set_active(false)  # stow the admin tool when equipping the perforator
		mining_tool.toggle_equip()

	if event.is_action_pressed("action"):
		# Standing in a seat box (on foot)? E takes that seat (driver left, passenger right).
		if _seat_vehicle_uuid == "" and is_instance_valid(_nearby_seat):
			_enter_seat(_nearby_seat)
			return
		# Otherwise pick up / drop. Send the uuid of the carriable under OUR crosshair so the
		# server grabs exactly that one (its own ray can be slightly off and grab a neighbour).
		interact_ray.force_raycast_update()
		var hit = interact_ray.get_collider()
		var target_uuid := ""
		if hit != null:
			var hp = hit.get_parent()
			if hp != null and hp.has_method("interact") and "uuid" in hp:
				target_uuid = str(hp.uuid)
		client_send_action_to_server({"action": "action", "target_uuid": target_uuid})
		_predict_carry_stow()

	if event.is_action_pressed("spawn_rock_mining"):
		if _spawn_wheel:
			_spawn_wheel.open([
				{"text": "Rocher", "data": "rock"},
				{"text": "Caisse", "data": "box"},
				{"text": "Dépôt", "data": "depot"},
				{"text": "Camion", "data": "truck"},
			])
	if event.is_action_released("spawn_rock_mining"):
		if _spawn_wheel:
			_spawn_wheel.confirm()

	if event.is_action_pressed("debug_console"):
		if _display_debug:
			display_debug.emit(false)
			_display_debug = false
		else:
			display_debug.emit(true)
			_display_debug = true

func server_set_input(input_dir: Vector2, newrotation: Vector3) -> void:
	input_from_server["input_direction"] = input_dir
	input_from_server["rotation"] = newrotation
	new_input_from_server = true

func _process(_delta: float) -> void:
	if remote_player:
		_interp.update(self, _delta)  # entity interpolation: glide between server updates
		return
	# Seated in a vehicle: ride the seat HERE, in sync with the vehicle's own _process
	# interpolation, so the camera stays glued to the (smoothly moving) cabin — no jitter/blur.
	if is_instance_valid(_seat_node):
		interact_label.hide()  # seated: clear any leftover "[E] Drive/Passenger Seat" prompt
		_ride_seat(_seat_node)
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

	# In front of a 3D screen (mining depot): free the mouse to click it + freeze the
	# camera. Otherwise capture the mouse and move the camera normally.
	# Free the mouse + freeze the camera while focused on UI (a 3D screen or the spawn wheel).
	var ui_focus: bool = screen_interacting != null or (_spawn_wheel != null and _spawn_wheel.visible)
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

	# Standing in a seat box (on foot): tell the player what E will do, or that it's taken.
	if is_instance_valid(_nearby_seat) and _seat_vehicle_uuid == "":
		if _seat_is_taken(_nearby_seat):
			interact_label.text = "Driver seat taken"
		else:
			interact_label.text = "[E] Drive Seat" if _nearby_seat.is_driver_seat() else "[E] Passenger Seat"
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
	var braking: bool = Input.is_physical_key_pressed(KEY_SPACE)
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

## Driver: a long press on Space at low speed toggles the vehicle's hand brake (once per hold).
func _update_handbrake_input(delta: float) -> void:
	if not Input.is_physical_key_pressed(KEY_SPACE):
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
		# Add the gravity.
		elif not is_on_floor():
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

		# Anti-tunnel safety: at high gravity / low frame-rate the
		# CharacterBody3D can still slip through ConcavePolygonShape3D
		# triangles between physics ticks.  Sample the planet's
		# heightmap (same data the collision mesh was generated from)
		# at the player's current direction; if the player ended up
		# below the surface, snap them back up and zero the radial
		# velocity.  Only runs when the player is inside a planet
		# gravity area, so flat / 0g zones are unaffected.
		if parent_gravity_area and parent_gravity_area.gravity_point \
				and parent_gravity_area.name == "PlanetGravity":
			_snap_to_planet_surface_if_below(parent_gravity_area)

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


## Snap the player back above the planet surface if move_and_slide tunneled
## through the collision mesh.  Samples the planet's heightmap (the same
## source used to build the ConcavePolygonShape3D) at the player's current
## body-frame direction, computes the surface radius there, and corrects
## the position + radial velocity if the player is below it.
##
## [param area] is the planet's gravity Area3D.  Its grand-parent is the
## Planet node; we walk up to find the PlanetTerrain / PlanetData.
func _snap_to_planet_surface_if_below(area: Area3D) -> void:
	var planet := area.get_parent().get_parent()
	if planet == null or not is_instance_valid(planet):
		return
	if not planet.has_method("get") or planet.get("planet_data") == null:
		return
	var pdata = planet.planet_data
	if pdata == null:
		return
	# Body-frame direction (planet rotates → must un-rotate world position).
	var local_world: Vector3 = global_position - planet.global_position
	if local_world.length_squared() < 1.0:
		return
	var local_body: Vector3 = planet.global_transform.basis.inverse() * local_world
	var dir: Vector3 = local_body.normalized()
	var player_dist: float = local_body.length()
	var surface_alt: float = pdata.sample_height_for_direction(dir)
	var surface_dist: float = pdata.radius + surface_alt
	# Small clearance so the next physics tick doesn't immediately re-collide.
	var clearance: float = 0.5
	if player_dist < surface_dist + clearance:
		var corrected_local: Vector3 = dir * (surface_dist + clearance)
		var corrected_world: Vector3 = planet.global_position \
				+ planet.global_transform.basis * corrected_local
		global_position = corrected_world
		# Zero the radial (downward) component of velocity; preserve any
		# tangential motion the player had before tunneling.
		var up_world: Vector3 = (planet.global_transform.basis * dir).normalized()
		var radial_speed: float = velocity.dot(up_world)
		if radial_speed < 0.0:
			velocity -= up_world * radial_speed

func orient_player():
	global_transform = global_transform.interpolate_with(Globals.align_with_y(global_transform, up_direction), 0.3)

func set_player_name(player_name):
	label_player_name.text = str(player_name)

func get_player_name():
	pass

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
	# elif area.is_in_group("spawn"):
	# 	var parent = area.get_parent()
	# 	print("TUTU: Entered spawn area, parent=", parent)
		# is_parented = true
		# emit_signal(
		# 	"hs_server_move",
		# 	client_uuid,
		# 	snapped(position, Vector3(0.001, 0.001, 0.001)),
		# 	snapped(global_rotation, Vector3(0.0001, 0.0001, 0.0001)),
		# 	parent.uuid,
		# 	is_parented
		# )
		# gravity_parents.push_back(area)

func _on_area_detector_area_exited(area: Area3D) -> void:
	if area.is_in_group("gravity"):
		if gravity_parents.has(area):
			gravity_parents.erase(area)
	elif area.is_in_group("spawn"):
		print("TUTU: Exited spawn area for area ", area)
		var new_parent = area.get_parent().get_parent()
		print("TUTU: Reparenting to ", new_parent)
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
		new_parent.uuid,
		is_parented
	)

func _set_player_global_position(pos, rot):
	global_position = pos
	global_rotation = rot

# Dev spawn wheel selection -> spawn the chosen prop in front of the player.
func _on_spawn_selected(data) -> void:
	match data:
		"rock":
			spawn_box("rock/rock_mining_01", "miningrock", 5.5, 1.2)
		"box":
			spawn_box("testbox/box_50cm", "box", 1.5, 2.0)
		"depot":
			_spawn_depot()
		"truck":
			_spawn_truck()

# Spawn a networked truck (server-authoritative vehicle prop) in front of the player. The
# server simulates its physics and replicates it to every client (B1 vehicle networking).
func _spawn_truck() -> void:
	var spawn_pos: Vector3 = position + (-global_basis.z * 8.0) + global_basis.y * 1.0
	var parent = get_parent()
	var parentuuid = "" if parent.name == "SystemSandbox" else parent.uuid
	client_send_action_to_server({
		"action": "spawn_vehicle",
		"position": {"x": spawn_pos.x, "y": spawn_pos.y, "z": spawn_pos.z},
		"parent_id": parentuuid,
	})

# LOCAL DEV (do not commit): spawn a mining depot a few meters in front of the player.
func _spawn_depot() -> void:
	var spawn_pos: Vector3 = position + (-global_basis.z * 10.0)
	var parent = get_parent()
	var parentuuid = "" if parent.name == "SystemSandbox" else parent.uuid
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
	var parentuuid = ""
	if parent.name == "SystemSandbox":
		parentuuid = ""
	else:
		parentuuid = parent.uuid
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
	if data.has("action"):
		match data["action"]:
			JUMP:
				is_jumping = true
			"toggle_flashlight":
				flashlight.visible = not flashlight.visible
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

## Owner-local: predict whether the carry key picks up or drops, to stow/unstow the
## perforator right away. The server stays authoritative (it may reject, e.g. a piece
## already taken); a mismatch self-corrects on the next interaction.
func _predict_carry_stow() -> void:
	if _owner_carrying:
		_owner_carrying = false
		mining_tool.set_stowed(false)
		return
	interact_ray.force_raycast_update()
	var collider = interact_ray.get_collider()
	var target = collider.get_parent() if collider != null else null
	if target != null and target.has_method("interact") and target.interact(self):
		_owner_carrying = true
		mining_tool.set_stowed(true)

# receive properties from the client, often the actions
func server_action_received(data: Dictionary) -> void:
	match data["action"]:
		JUMP:
			is_jumping = true
		"toggle_flashlight":
			flashlight.visible = not flashlight.visible
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
		"action":
			print("action key pressed by player")
			if hands_item != null:
				# we have something in hands, so release it
				print("player has an item in hands, dropping it")
				# Generic: let the object know it is no longer carried (issue #124).
				if hands_item.has_method("set_carried"):
					hands_item.set_carried(false)
				hands_item.server_parent_change(get_parent())
				hands_item.freeze = false
				hands_item.send_properties_to_client(get_parent().uuid)
				hands_item = null
				# Stop carrying on all clients (perforator comes back) (issue #124).
				server_send_properties_to_client({"carrying": false})
			else:
				# Pick up the carriable the CLIENT aimed at: it sends the uuid under its
				# crosshair, so we grab exactly that one. (Our own server ray can be a hair
				# off — pitch is throttled/lagged — and would grab the neighbour.) (#124)
				var parent_node := _find_carriable(str(data.get("target_uuid", "")))
				var picked_up := false
				if parent_node != null and parent_node.has_method("interact") and parent_node.interact(self):
					parent_node.freeze = true
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
