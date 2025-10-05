class_name Player

extends CharacterBody3D

signal hs_client_action_move
signal hs_server_move

@warning_ignore("unused_signal")
signal client_action_requested(datas: Dictionary)

#const MOVE_FORWARD: String = "move_forward"
#const MOVE_BACK: String = "move_back"
#const MOVE_LEFT: String = "move_left"
#const MOVE_RIGHT: String = "move_right"
#const JUMP: String = "jump"
#const CROUCH: String = "crouch"
#const SPRINT: String = "sprint"
#const PAUSE: String = "pause"

@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EntityControllability") var controllability_component: EntityControllability
#@export var controllability_component: EntityControllability

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

#var input_direction: Vector2
var movement_strength: float
#var mouse_motion: Vector2
var is_jumping: bool = false

var spawn_position: Vector3 = Vector3.ZERO
var spawn_up: Vector3 = Vector3.UP

var can_interact: bool = false


var gravity_parents: Array[Area3D]

var last_basis: Basis
var puppet_player: bool = false
var input_from_server: Dictionary = {
	"input_direction": Vector2.ZERO,
	"rotation": Vector3.ZERO
}
var new_input_from_server: bool = false

#var client_last_input_direction = Vector2.ZERO
var client_last_global_rotation = Vector3.ZERO

var is_parented: bool = false

# to disable player input when piloting vehicule/ship
var active = false

@onready var camera_pov: Camera3D = $CameraPivot/Camera3D
@onready var camera_ext: Camera3D = $ExtCamera3D

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

func _enter_tree() -> void:
	$UserInterface/LoadingScreen.hide()

	if name.begins_with("remoteplayer"):
		puppet_player = true
		global_position = spawn_position
		$UserInterface.visible = false
		$CameraPivot.visible = false

	else:
		if not NetworkOrchestrator.set_player_global_position.is_connected(_set_player_global_position):
			NetworkOrchestrator.set_player_global_position.connect(_set_player_global_position)

func _ready() -> void:
	if puppet_player:
		camera_pov.current = false
		$ExtCamera3D.current = false
		set_player_name(name)
		return
	
	if GameOrchestrator.current_network_role == GameOrchestrator.NetworkRole.PLAYER:
		$UserInterface/LoadingScreen.show()


	global_position = spawn_position
	look_at(global_transform.origin + Vector3.FORWARD, spawn_up)

	NetworkOrchestrator.set_gameserver_name.connect(_set_gameserver_name)

	client_uuid = Globals.player_uuid
	self.set_meta("client_uuid", Globals.player_uuid)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	camera_pov.current = false
	$ExtCamera3D.current = false

	camera_pov.make_current()
	# hide player name label for me only
	label_player_name.visible = false
	label_server_name.visible = false
	astronaut.visible = false
	interact_label.hide()
	connect_area_detect()
	active = false
	
	if GameOrchestrator.current_network_role == GameOrchestrator.NetworkRole.PLAYER:
		print_rich("[color=gree]JE VEUX ATTENDRE LES 5 SECONDES[/color]")
		await get_tree().create_timer(5).timeout
		$UserInterface/LoadingScreen.hide()

	update_last_basis()

	active = true


func set_uuid(uuid: String) -> void:
	client_uuid = uuid
	self.set_meta("client_uuid", uuid)

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
	if puppet_player: return
	if !active: return
	
	if controllability_component:
		controllability_component.handle_input(event)

func _process(_delta: float) -> void:
	if puppet_player: return
	if !active:
		interact_label.hide()
		return

	if controllability_component:
		controllability_component.process(_delta)

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

		labelx.text = str("%0.2f" % global_position[0])
		labely.text = str("%0.2f" % global_position[1])
		labelz.text = str("%0.2f" % global_position[2])

func _physics_process(_delta: float) -> void:
	if puppet_player: return
	
	if controllability_component:
		controllability_component.physics_process(_delta)

		labelx.text = str("%0.2f" % global_position[0])
		labely.text = str("%0.2f" % global_position[1])
		labelz.text = str("%0.2f" % global_position[2])

func should_listen_input() -> bool:
	return not (direct_chat.is_shown || MenuConfig.is_shown)

func set_player_name(player_name):
	label_player_name.text = str(player_name)

func get_player_name():
	pass

func _on_area_detector_area_entered(area: Area3D) -> void:
	if area.is_in_group("gravity"):
		if area.name == "PlanetGravity":
			var planet = area.get_parent().get_parent()
			#reparent(planet)
			call_deferred("reparent", planet)
			is_parented = true
			emit_signal("hs_server_move", client_uuid, position, global_rotation, planet.uuid, is_parented)
		
		gravity_parents.push_back(area)

func _on_area_detector_area_exited(area: Area3D) -> void:
	if area.is_in_group("gravity"):
		if gravity_parents.has(area):
			gravity_parents.erase(area)

func _set_gameserver_name(server_name: String):
	label_server_name.text = "(" + server_name + ")"

func _set_player_global_position(pos, rot):
	global_position = pos
	global_rotation = rot

func spawn_box50cm():
	var box_spawn_position: Vector3 = global_position + (-global_basis.z * 1.5) + global_basis.y * 2.0
	emit_signal(
		"client_action_requested",
		{"action": "spawn", "entity": "box50cm", "spawn_position": box_spawn_position, "uuid": client_uuid}
	)
