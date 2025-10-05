@abstract
extends RefCounted
class_name EntityControllability

var entity_reference: WeakRef = weakref(null)

var entity: Node3D:
	set(value):
		if is_instance_valid(value) and value != entity:
			entity_reference = weakref(value)
	get:
		return entity_reference.get_ref()

const MOVE_FORWARD: String = "move_forward"
const MOVE_BACK: String = "move_back"
const MOVE_LEFT: String = "move_left"
const MOVE_RIGHT: String = "move_right"
const JUMP: String = "jump"
const CROUCH: String = "crouch"
const SPRINT: String = "sprint"
const PAUSE: String = "pause"

var input_direction: Vector2
var mouse_motion: Vector2

var client_last_input_direction = Vector2.ZERO

func _init() -> void:
	pass

func handle_input(_event: InputEvent) -> void:
	push_error("handle_input(event) must be implemented by the derived class.")
	pass

func process(_delta: float) -> void:
	push_error("process(_delta: float) must be implemented by the derived class.")
	pass

func physics_process(_delta: float) -> void:
	push_error("physics_process(delta: float) must be implemented by the derived class.")
	pass

func handle_camera_motion():
	if entity.gravity == 0:
		entity.camera_pivot.rotation.x = 0
		entity.rotate_object_local(Vector3.UP, mouse_motion.x  * entity.camera_sensitivity)
		entity.rotate_object_local(Vector3.RIGHT, mouse_motion.y  * entity.camera_sensitivity)
	else:
		orient_player()
		entity.global_basis = entity.global_basis.rotated(entity.global_basis.y, mouse_motion.x * entity.camera_sensitivity)
		entity.camera_pivot.rotate_object_local(Vector3.RIGHT, mouse_motion.y  * entity.camera_sensitivity)
		entity.camera_pivot.rotation_degrees.x = clamp(entity.camera_pivot.rotation_degrees.x, -80, 80)
	mouse_motion = Vector2.ZERO

func orient_player():
	entity.global_transform = entity.global_transform.interpolate_with(Globals.align_with_y(entity.global_transform, entity.up_direction), 0.3)
