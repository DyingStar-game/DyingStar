class_name Player

extends CharacterBody3D

signal hs_client_action_move
signal hs_server_move
signal hs_client_action_pressed
signal display_debug(show: bool)

@warning_ignore("unused_signal")
signal client_action_requested(datas: Dictionary)

enum Characters {SOLDIER, ALIEN}

const CHARACTERS_SCENES_PATHS: Dictionary = {
	Characters.SOLDIER : "res://assets/models/characters/soldier/Soldier.tscn",
	Characters.ALIEN : "res://assets/models/characters/alien/Alien.tscn",
}

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

var active_character: int = Characters.SOLDIER
var character_instance: Node3D

var client_uuid: String = ""

var player_display_name: String = ""

var input_direction: Vector2
var movement_strength: float
var mouse_motion: Vector2
var is_jumping: bool = false

var spawn_position: Vector3 = Vector3.ZERO
var spawn_up: Vector3 = Vector3.UP

var can_interact: bool = false


var gravity_parents: Array[Area3D]

var last_basis: Basis
var remote_player: bool = false
var input_from_server: Dictionary = {
	"input_direction": Vector2.ZERO,
	"rotation": Vector3.ZERO
}
var new_input_from_server: bool = false

var last_position: Vector3
var physics_tick: int = 0

var client_last_input_direction = Vector2.ZERO
var client_last_global_rotation = Vector3.ZERO

var is_parented: bool = false

# to disable player input when piloting vehicule/ship
var active = false

var _display_debug:bool = false

@onready var camera = $CameraPivot/Camera3D

@onready var labelx: Label = $UserInterface/Debug/LabelXValue
@onready var labely: Label = $UserInterface/Debug/LabelYValue
@onready var labelz: Label = $UserInterface/Debug/LabelZValue
@onready var label_player_name: Label3D = %LabelPlayerName
@onready var label_server_name: Label3D = %Labelserver_name
@onready var interact_ray: RayCast3D = $CameraPivot/Camera3D/InteractRay
@onready var interact_label: Label = $UserInterface/HUD/InteractLabel
@onready var camera_pivot: Node3D = $CameraPivot

@onready var direct_chat: DirectChat = $UserInterface/DirectChat

@onready var box4m: PackedScene = preload("res://scenes/props/testbox/box_4m.tscn")
@onready var box50m: PackedScene = preload("res://scenes/props/testbox/box_50cm.tscn")
@onready var is_inside_box4m: bool = false

@onready var flashlight: SpotLight3D = $CameraPivot/Camera3D/Torch
@onready var animation_tree: AnimationTree = $AnimationTree
@onready var collider: CollisionShape3D = $Placeholder_Collider

func _enter_tree() -> void:
	if name.begins_with("remoteplayer"):
		remote_player = true
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

	if remote_player:
		camera.current = false
		$ExtCamera3D.current = false
		set_player_name(name)
		return

	if not OS.has_feature("dedicated_server"):
		$UserInterface/LoadingScreen.show()
		$UserInterface/PauseMenu.cycle_character.connect(_on_cycle_character)

		if collider.has_node("Character"):
			character_instance = collider.get_node("Character")

		global_position = spawn_position
		look_at(global_transform.origin + Vector3.FORWARD, spawn_up)

		position = spawn_position
		global_transform = Globals.align_with_y(global_transform, spawn_up)

		client_uuid = Globals.player_uuid
		self.set_meta("client_uuid", Globals.player_uuid)

		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		camera.current = false
		$ExtCamera3D.current = false

		camera.make_current()
		# hide player name label for me only
		label_player_name.visible = false
		label_server_name.visible = false
		interact_label.hide()
		connect_area_detect()
		active = false

		await get_tree().create_timer(5).timeout

		update_last_basis()

		active = true

		$UserInterface/LoadingScreen.hide()
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
	#$AreaDetector.area_entered.connect(_on_area_detector_area_entered)
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
		emit_signal("hs_client_action_pressed", JUMP)

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		mouse_motion = -event.relative * 0.001

	if event.is_action_pressed("toggle_flashlight"):
		flashlight.visible = not flashlight.visible

	if event.is_action_pressed("spawn_50cmbox"):
		spawn_box("testbox/box_50cm", "box", 1.5, 2.0)

	if event.is_action_pressed("spawn_4mbox"):
		spawn_box("testbox/box_4m", "box", 3.0, 6.0)

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
			if collider.has_node("Character"):
				collider.get_node("Character").hide()
		else:
			if collider.has_node("Character"):
				collider.get_node("Character").show()
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

	_handle_camera_motion()

	interact_label.hide()
	can_interact = false
	if interact_ray.is_colliding():
		var collider = interact_ray.get_collider()
		if collider.has_method("interact"):
			interact_label.text = collider.label
			interact_label.show()
			can_interact = true
			if Input.is_action_just_pressed("interact"):
				collider.interact(self)
				interact_label.hide()


	if not OS.has_feature("dedicated_server"):
		# player part
		if !active: return

		var dir_vect = Vector3.ZERO
		var sprint = null

		#apply_parent_movement()

		if not direct_chat.can_write:
			dir_vect = Input.get_vector(MOVE_LEFT, MOVE_RIGHT, MOVE_FORWARD, MOVE_BACK)
			sprint = Input.is_action_pressed(SPRINT)

		if dir_vect:
			input_direction = lerp(input_direction, dir_vect, 0.1)
		else:
			input_direction = Vector2.ZERO
		# send move_direction
		var short_rotation = snapped(global_rotation, Vector3(0.0001, 0.0001, 0.0001))
		if input_direction != client_last_input_direction or short_rotation != client_last_global_rotation:
			client_last_input_direction = input_direction
			client_last_global_rotation = short_rotation
			emit_signal("hs_client_action_move", input_direction, short_rotation)
		update_last_basis()
		#animation_tree.set("parameters/BlendSpace2D/blend_position", input_direction / 1.0)

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

				gravity = parent_gravity_area.gravity
				motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
			else:
				# 0g movement
				gravity = 0.0
				camera_pivot.rotation.x = 0
				motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
				var dir = Vector3(input_direction.x, 0, input_direction.y)

				velocity += global_basis * dir * player_thruster_force * delta
				velocity *= 0.98

			var move_direction = (global_transform.basis * Vector3(input_direction.x, 0, input_direction.y)).normalized()

			var speed = sprint_speed if sprint else walk_speed

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

			move_and_slide()
			update_last_basis()

			new_input_from_server = false
		else:
			move_and_slide()
			update_last_basis()

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
		physics_tick += 1
		if physics_tick >= 5:
			var player_velocity: float = (global_position - last_position).length()

			if player_velocity > 1.0:
				animation_tree.set("parameters/conditions/idle", false)
				animation_tree.set("parameters/conditions/walk", false)
				animation_tree.set("parameters/conditions/run", true)
			if player_velocity > 0.1:
				animation_tree.set("parameters/conditions/idle", false)
				animation_tree.set("parameters/conditions/run", false)
				animation_tree.set("parameters/conditions/walk", true)
			else:
				animation_tree.set("parameters/conditions/walk", false)
				animation_tree.set("parameters/conditions/run", false)
				animation_tree.set("parameters/conditions/idle", true)

			last_position = global_position
			physics_tick = 0

func should_listen_input() -> bool:
	return not (direct_chat.is_shown || MenuConfig.is_shown)

func _handle_camera_motion():
	var parent_gravity_area: Area3D = gravity_parents.back() if not gravity_parents.is_empty() else null

	if parent_gravity_area:
		if parent_gravity_area.gravity_point:
			up_direction = parent_gravity_area.global_position.direction_to(global_position)
		else:
			up_direction = parent_gravity_area.global_basis.y

		gravity = parent_gravity_area.gravity
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
			emit_signal("hs_server_move", client_uuid, position, global_rotation, planet.uuid, is_parented)
		gravity_parents.push_back(area)

func _on_area_detector_area_exited(area: Area3D) -> void:
	if area.is_in_group("gravity"):
		if gravity_parents.has(area):
			gravity_parents.erase(area)

func _on_cycle_character() -> void:
	var next_character: int = (active_character + 1) % Characters.size()
	_change_character(next_character)

func _change_character(character: int) -> void:
	if is_instance_valid(character_instance):
		character_instance.name = "old_character"
		animation_tree.active = false
		character_instance.queue_free()

	character_instance = load(CHARACTERS_SCENES_PATHS[character]).instantiate()
	character_instance.name = "Character"
	character_instance.translate(Vector3(0.0,-0.9,0.0))
	character_instance.rotate_y(deg_to_rad(180.0))

	character_instance.tree_entered.connect(func():
		character_instance.owner = self.owner if self.owner else self
		active_character = character
		if collider.has_node("Character"):
			if animation_tree.has_node(animation_tree.anim_player):
				animation_tree.get_node(animation_tree.anim_player).set_root_node(collider.get_path())
				animation_tree.active = true
				animation_tree.set("parameters/conditions/walk", true)
	, CONNECT_ONE_SHOT)
	collider.add_child(character_instance)

func _set_player_global_position(pos, rot):
	global_position = pos
	global_rotation = rot

func spawn_box(boxscene: String, type: String, coeffz: float, coeffy: float):
	var item_spawn_position: Vector3 = position + (-global_basis.z * coeffz) + global_basis.y * coeffy
	# parent is for example the planet
	var parent = get_parent();
	var parentuuid = ""
	if parent.name == "SystemSandbox":
		parentuuid = ""
	else:
		parentuuid = parent.uuid

	emit_signal(
		"client_action_requested",
		{
			"action": "spawn",
			"entity": type,
			"position": {
				"x": item_spawn_position[0],
				"y": item_spawn_position[1],
				"z": item_spawn_position[2]
			},
			"scenename": "scenes/props/" + boxscene + ".tscn",
			"parent_id": parentuuid,
		}
	)
