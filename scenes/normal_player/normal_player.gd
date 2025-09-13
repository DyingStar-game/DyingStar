extends CharacterBody3D
class_name Player

signal hs_client_action_move
signal hs_server_move

@warning_ignore("unused_signal")
signal client_action_requested(datas: Dictionary)

@onready var camera = $CameraPivot/Camera3D

@onready var labelx: Label = $UserInterface/Debug/LabelXValue
@onready var labely: Label = $UserInterface/Debug/LabelYValue
@onready var labelz: Label = $UserInterface/Debug/LabelZValue
@onready var labelPlayerName: Label3D = %LabelPlayerName
@onready var labelServerName: Label3D = %LabelServerName
@onready var astronaut: Node3D = $Placeholder_Collider/Astronaut
@onready var interact_ray: RayCast3D = $CameraPivot/Camera3D/InteractRay
@onready var interact_label: Label = $UserInterface/HUD/InteractLabel
@onready var camera_pivot: Node3D = $CameraPivot

@onready var direct_chat: DirectChat = $UserInterface/DirectChat

@onready var box4m: PackedScene = preload("res://scenes/props/testbox/box_4m.tscn")
@onready var box50m: PackedScene = preload("res://scenes/props/testbox/box_50cm.tscn")
@onready var isInsideBox4m: bool = false

@onready var game_is_paused: bool = false

@export_group("Controls map names")
@export var MOVE_FORWARD: String = "move_forward"
@export var MOVE_BACK: String = "move_back"
@export var MOVE_LEFT: String = "move_left"
@export var MOVE_RIGHT: String = "move_right"
@export var JUMP: String = "jump"
@export var CROUCH: String = "crouch"
@export var SPRINT: String = "sprint"
@export var PAUSE: String = "pause"

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

var clientUUID: String = ""

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

var client_last_input_direction = Vector2.ZERO
var client_last_global_rotation = Vector3.ZERO


# to disable player input when piloting vehicule/ship
var active = false

func _enter_tree() -> void:
	$UserInterface/LoadingScreen.hide()
	
	if name.begins_with("remoteplayer"):
		remote_player = true
		global_position = spawn_position
		
	else:
		NetworkOrchestrator.set_player_global_position.connect(_set_player_global_position)

func _ready() -> void:
	if remote_player:
		return
	
	$UserInterface/LoadingScreen.show()
	
		
	global_position = spawn_position
	look_at(global_transform.origin + Vector3.FORWARD, spawn_up)
	
	NetworkOrchestrator.set_gameserver_name.connect(_set_gameserver_name)

	clientUUID = Globals.playerUUID
	self.set_meta("clientUUID", Globals.playerUUID)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	camera.current = false
	$ExtCamera3D.current = false
	# hide player name label for me only
	labelPlayerName.visible = false
	labelServerName.visible = false
	astronaut.visible = false
	interact_label.hide()
	connect_area_detect()
	active = false
	
	await get_tree().create_timer(5).timeout
	
	update_last_basis()
	
	active = true
	
	$UserInterface/LoadingScreen.hide()

func set_uuid(uuid: String) -> void:
	clientUUID = uuid
	self.set_meta("clientUUID", uuid)

func connect_area_detect():
	$AreaDetector.area_entered.connect(_on_area_detector_area_entered)
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
		
	if event.is_action_pressed(JUMP) and is_on_floor():
		is_jumping = true
	
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		mouse_motion = -event.relative * 0.001
	
	if event.is_action_pressed("spawn_50cmbox"):
		var box_spawn_position: Vector3 = global_position + (-global_basis.z * 1.5) + global_basis.y * 2.0
		emit_signal("client_action_requested", {"action": "spawn", "entity": "box50cm", "spawn_position": box_spawn_position})
	
	if event.is_action_pressed("spawn_4mbox"):
		var box_spawn_position: Vector3 = global_position + (-global_basis.z * 3.0) + global_basis.y * 6.0
		
		var player_up = global_transform.basis.y.normalized()
		var to_player = (global_transform.origin - box_spawn_position)
		to_player -= to_player.dot(player_up) * player_up
		to_player = to_player.normalized()
		var box_basis: Basis = Basis.looking_at(to_player, player_up)
		var box_spawn_rotation = box_basis.get_euler()
		
		emit_signal("client_action_requested", {"action": "spawn", "entity": "box4m", "spawn_position": box_spawn_position, "spawn_rotation": box_spawn_rotation})
	
	if Input.is_action_just_pressed("ext_cam"):
		if $ExtCamera3D.current:
			camera.make_current()
			astronaut.visible = false
		else:
			astronaut.visible = true
			$ExtCamera3D.make_current()

func server_set_input(input_dir: Vector2, rotation: Vector3) -> void:
	input_from_server["input_direction"] = input_dir
	input_from_server["rotation"] = rotation
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
		if input_direction != client_last_input_direction or global_rotation != client_last_global_rotation:
			client_last_input_direction = input_direction
			client_last_global_rotation = global_rotation
			emit_signal("hs_client_action_move", input_direction, global_rotation)
		update_last_basis()
		
		labelx.text = str("%0.2f" % global_position[0])
		labely.text = str("%0.2f" % global_position[1])
		labelz.text = str("%0.2f" % global_position[2])

func _physics_process(delta: float) -> void:
	if OS.has_feature("dedicated_server"):
		if new_input_from_server:
			input_direction = input_from_server["input_direction"]
			global_rotation = input_from_server["rotation"]

			var sprint = null

			var parent_gravity_area: Area3D = gravity_parents.back() if not gravity_parents.is_empty() else null
			
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
				
			move_and_slide()
			update_last_basis()

			new_input_from_server = false
		else:
			move_and_slide()
			update_last_basis()

		emit_signal("hs_server_move", clientUUID, global_position, global_rotation)
		return

	else:
		# player part
		if remote_player: return
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
		if input_direction != client_last_input_direction or global_rotation != client_last_global_rotation:
			client_last_input_direction = input_direction
			client_last_global_rotation = global_rotation
			emit_signal("hs_client_action_move", input_direction, global_rotation)
		update_last_basis()
		
		labelx.text = str("%0.2f" % global_position[0])
		labely.text = str("%0.2f" % global_position[1])
		labelz.text = str("%0.2f" % global_position[2])

func should_listen_input() -> bool:
	return not (direct_chat.is_shown || MenuConfig.is_shown)

func _handle_camera_motion():
	if gravity == 0:
		camera_pivot.rotation.x = 0
		rotate_object_local(Vector3.UP, mouse_motion.x  * camera_sensitivity)
		rotate_object_local(Vector3.RIGHT, mouse_motion.y  * camera_sensitivity)
	else:
		orient_player()
		global_basis = global_basis.rotated(global_basis.y, mouse_motion.x * camera_sensitivity)
		camera_pivot.rotate_object_local(Vector3.RIGHT, mouse_motion.y  * camera_sensitivity)
		camera_pivot.rotation_degrees.x = clamp(camera_pivot.rotation_degrees.x, -80, 80)
	mouse_motion = Vector2.ZERO

func orient_player():
	global_transform = global_transform.interpolate_with(Globals.align_with_y(global_transform, up_direction), 0.3)

func set_player_name(player_name):
	labelPlayerName.text = str(player_name)
	
func get_player_name():
	pass

func _on_area_detector_area_entered(area: Area3D) -> void:
	if area.is_in_group("gravity"):
		gravity_parents.push_back(area)

func _on_area_detector_area_exited(area: Area3D) -> void:
	if area.is_in_group("gravity"):
		if gravity_parents.has(area):
			gravity_parents.erase(area)

func _set_gameserver_name(server_name: String):
	labelServerName.text = "(" + server_name + ")"

func _set_player_global_position(pos, rot):
	global_position = pos
	global_rotation =rot
