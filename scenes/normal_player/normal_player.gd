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

@export_group("Controls map names")

@export_group("Customizable player stats")
@export var walk_back_speed: float = 1.5
@export var walk_speed: float = 2.5
@export var player_thruster_force = 10
@export var sprint_speed: float = 5.0
@export var crouch_speed: float = 1.5
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

var hands_item: Node3D = null

var _display_debug:bool = false


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
		$ExtCamera3D.current = false
		set_player_name(name)
		return

	if not OS.has_feature("dedicated_server"):
		$UserInterface/LoadingScreen.show()

		global_position = spawn_position
		look_at(global_transform.origin + Vector3.FORWARD, spawn_up)

		position = spawn_position
		global_transform = Globals.align_with_y(global_transform, spawn_up)

		client_uuid = Globals.player_uuid
		self.set_meta("client_uuid", Globals.player_uuid)

		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		camera.current = true
		$ExtCamera3D.current = true

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
	if !active: return

	if event.is_action_pressed(JUMP):
		client_send_action_to_server({"action": JUMP})

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		mouse_motion = -event.relative * 0.001

	if event.is_action_pressed("toggle_flashlight"):
		client_send_action_to_server({"action": "toggle_flashlight"})
		# flashlight.visible = not flashlight.visible

	if event.is_action_pressed("toggle_tool"):
		mining_tool.toggle_equip()

	if event.is_action_pressed("spawn_50cmbox"):
		spawn_box("testbox/box_50cm", "box", 1.5, 2.0)

	if event.is_action_pressed("action"):
		#  action key
		client_send_action_to_server({"action": "action"})

	if event.is_action_pressed("spawn_rock_mining"):
		spawn_box("rock/rock_mining_01", "miningrock", 5.5, 1.2)

	if event.is_action_pressed("debug_console"):
		if _display_debug:
			display_debug.emit(false)
			_display_debug = false
		else:
			display_debug.emit(true)
			_display_debug = true

	if Input.is_action_just_pressed("ext_cam"):
		if $ExtCamera3D.current:
			camera.make_current()
			astronaut.visible = false
		else:
			astronaut.visible = true
			$ExtCamera3D.make_current()

func server_set_input(input_dir: Vector2, newrotation: Vector3) -> void:
	input_from_server["input_direction"] = input_dir
	input_from_server["rotation"] = newrotation
	new_input_from_server = true

func _process(_delta: float) -> void:
	if remote_player: return
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

func _physics_process(delta: float) -> void:
	if remote_player: return
	if OS.has_feature("dedicated_server"):
		if new_input_from_server:
			input_direction = input_from_server["input_direction"]
			global_rotation = input_from_server["rotation"]

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

func spawn_box(_boxscene: String, _type: String, _coeffz: float, _coeffy: float):
	# disabled for the moment because take too many FPS on server
	pass
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

## Find a spawned mining rock by its uuid (server-side).
func _find_mining_rock(rock_uuid: String) -> Node:
	if rock_uuid == "":
		return null
	for r in get_tree().get_nodes_in_group("miningrock"):
		if "uuid" in r and str(r.uuid) == rock_uuid:
			return r
	return null

# receive properties from the client, often the actions
func server_action_received(data: Dictionary) -> void:
	match data["action"]:
		JUMP:
			is_jumping = true
		"toggle_flashlight":
			flashlight.visible = not flashlight.visible
		"equip_tool":
			# Authoritative tool state, then replicate it to nearby clients.
			var tool_id: String = data.get("tools", "")
			mining_tool.server_set_tool(tool_id)
			server_send_properties_to_client({"tools": tool_id})
		"set_head":
			# Replicate the camera pitch so others see where this player aims.
			server_send_properties_to_client({"head": data.get("head", 0.0)})
		"set_perforating":
			# Replicate the perforation state so others see the jackhammer animation.
			server_send_properties_to_client({"perforating": data.get("perforating", false)})
		"perforate_rock":
			# Authoritative fracture: cut the targeted rock along the aimed fault.
			var rock := _find_mining_rock(str(data.get("uuid", "")))
			if rock and rock.has_method("server_perforate"):
				var h: Dictionary = data.get("hit", {})
				rock.server_perforate(Vector3(h.get("x", 0.0), h.get("y", 0.0), h.get("z", 0.0)))
		"action":
			print("action key pressed by player")
			if hands_item != null:
				# we have something in hands, so release it
				print("player has an item in hands, dropping it")
				hands_item.server_parent_change(get_parent())
				hands_item.freeze = false
				hands_item.send_properties_to_client(get_parent().uuid)
				hands_item = null
			else:
				# generic action key pressed
				print("action key pressed for collider")
				var collider = interact_ray.get_collider()
				if collider != null:
					var parent_node = collider.get_parent()
					if parent_node.has_method("interact"):
						print("Collider has interact method")
						var can_interact = parent_node.interact(self)
						if can_interact:
							print("collider 01")
							parent_node.freeze = true
							parent_node.server_parent_change(self)
							parent_node.position = Vector3(0.0, 1.0, -1.0)
							#  send reparent to client
							parent_node.send_properties_to_client(self.client_uuid)
							hands_item = parent_node

			# TODO
			# synchro head/camera
