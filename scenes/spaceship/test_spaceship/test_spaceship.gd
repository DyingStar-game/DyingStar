extends RigidBody3D
class_name Spaceship

@onready var pilot_seat: RemoteTransform3D = $PilotSeat
@onready var ship_console: Interactable = $ShipConsole

@export var speed = 300
@export var roll_speed = 100
@export var mouse_sensitivity = 0.01

var active = false

var type_name = "ship"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.ZERO

var force_multiplier = 1000
var gravity_area: Area3D
var pilot: Player = null
var pause_mode = false

var gravity_parents: Array[Area3D]
var last_basis: Basis

func _ready() -> void:
	global_position = spawn_position
	global_rotation = spawn_rotation
	$StaticBody3D.add_collision_exception_with(self)
	ship_console.interacted.connect(on_ship_console_interact)
	
	update_last_basis()

func on_ship_console_interact(interactor: Node):
	if interactor is Player and not GameOrchestrator.is_server():
		interactor.emit_signal("client_action_requested", {"action": "control", "entity": "ship", "entity_node": self})

func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	
	if not is_multiplayer_authority(): return
		
	#if pause_mode and event is InputEventMouseButton:
		#Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		#pause_mode = false
	
	#if pilot.direct_chat.is_shown: return
	
	if Input.is_action_just_pressed("exit"):
		pilot.emit_signal("client_action_requested", {"action": "release_control", "entity": "ship", "entity_node": self})
		
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		steer_ship_mouse(event.screen_relative)

func steer_ship_mouse(dir: Vector2) -> void:
	apply_torque_impulse(-global_transform.basis.x * dir.y * mouse_sensitivity * force_multiplier)
	apply_torque_impulse(-global_transform.basis.y * dir.x * mouse_sensitivity * force_multiplier)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority(): return
	
	if MenuConfig.is_shown: return
	
	if pilot:
		active = true
	
	var dir = Vector3.ZERO
	var roll = Vector3.ZERO
		
	var boost = false
	
	$ShipPhysicsGrid.gravity_direction = -global_basis.y
	
	if active and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		
		dir = Vector3(
			Input.get_axis("move_left", "move_right"),
			Input.get_axis("strafe_down", "strafe_up"),
			Input.get_axis("move_forward", "move_back"),
		)
		
		
		roll = Vector3(0, 0, -Input.get_axis("roll_left", "roll_right"))


	var speed_multiplier = 20.0 if boost else 1.0
	
	var force = dir.normalized() * speed * force_multiplier * speed_multiplier * delta
	
	apply_central_force(global_transform.basis * force);
	
	var roll_force = roll * roll_speed * force_multiplier * delta
	apply_torque(global_transform.basis * roll_force)
	
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	#apply_parent_movement(state)
	
	update_last_basis()
	
func get_current_gravity_parent() -> Node3D:
	if gravity_parents.is_empty(): return null
	return gravity_parents.back()

func apply_parent_movement(state: PhysicsDirectBodyState3D) -> void:
	var gravity_parent = get_current_gravity_parent()
	if !gravity_parent: return
	if !last_basis: return
	
	var current_basis = gravity_parent.global_transform.basis
	var delta_rot = current_basis * last_basis.inverse()

	var local_pos = state.transform.origin - gravity_parent.global_position
	var rotated = delta_rot * local_pos

	
	state.transform.basis = delta_rot * state.transform.basis
	state.transform.origin = gravity_parent.global_position + rotated
	


func update_last_basis() -> void:
	var gravity_parent = get_current_gravity_parent()
	if !gravity_parent: return
	
	last_basis = gravity_parent.global_transform.basis


func _on_collision_area_entered(area: Area3D) -> void:
	if area.is_in_group("gravity"):
		gravity_parents.push_back(area)

func _on_collision_area_exited(area: Area3D) -> void:
	if area.is_in_group("gravity"):
		if gravity_parents.has(area):
			gravity_parents.erase(area)

func _on_gravity_area_body_entered(body: PhysicsBody3D) -> void:
	add_collision_exception_with(body)

	
func _on_gravity_area_body_exited(body: Node3D) -> void:
	if pilot and body == pilot: return
	remove_collision_exception_with(body)
	
