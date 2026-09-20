extends RigidBody3D


@onready var _platform_interface: Control = %"Platform Interface"

var weight_on_platform: float = 0.0
var _player_custom_force: float = 0.0

var _total_impulse_force: float = 0.0
var _unique_bodies_on_platform: Dictionary = {}


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 10


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var total_force_in_newtons: float = 0.0
	var local_gravity: Vector3 = state.total_gravity
	var up_direction: Vector3 = -local_gravity.normalized()
	var gravity_magnitude: float = local_gravity.length()
	
	for i in state.get_contact_count():
		var object_in_contact: Object = state.get_contact_collider_object(i)
		var normal: Vector3 = state.get_contact_local_normal(i)
		
		if normal.dot(up_direction) <- 0.5:
			var impulse: Vector3 = state.get_contact_impulse(i)
			_total_impulse_force += abs(impulse.dot(up_direction)) / state.step
			
			_unique_bodies_on_platform[object_in_contact] = true
	
	var total_static_force: float = 0.0
	for body in _unique_bodies_on_platform:
		if body is RigidBody3D:
			total_static_force += body.mass * gravity_magnitude
		if body is CharacterBody3D and "player_mass" in body:
			total_static_force += body.player_mass * gravity_magnitude
	
	total_force_in_newtons = max(total_static_force, _total_impulse_force) + _player_custom_force
	_player_custom_force = 0.0
	
	if gravity_magnitude > 0.001:
		weight_on_platform = total_force_in_newtons / gravity_magnitude
	else:
		weight_on_platform = 0.0
	
	_unique_bodies_on_platform.clear()
	_total_impulse_force = 0.0
	
	if _platform_interface:
		_platform_interface.display_new_weight(weight_on_platform)


func add_kinematic_force(force: float) -> void:
	_player_custom_force += force
	sleeping = false
