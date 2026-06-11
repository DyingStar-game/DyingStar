class_name BenchPilot
extends CharacterBody3D

## Minimal test pilot for the vehicle bench: walk (WASD, relative to the camera) and press E
## next to a vehicle to drive it. Throwaway harness — the real networked player replaces it
## in the game (brick 3). Looking around is the shared orbit camera (right mouse).

@export var speed: float = 6.0
@export var gravity: float = 14.0
## How close to a vehicle you must be to enter it.
@export var interact_distance: float = 5.0

var _vehicle: Node3D = null

func _ready() -> void:
	add_to_group("pilot")

## Called by the vehicle when we take the wheel: stop walking, drop collision. We stay
## visible — the vehicle seats us in the cab.
func set_driving(vehicle: Node3D) -> void:
	_vehicle = vehicle
	velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	set_physics_process(false)

## Called by the vehicle when we step out: walk again.
func set_walking() -> void:
	_vehicle = null
	collision_layer = 1
	collision_mask = 1
	set_physics_process(true)

func _unhandled_input(event: InputEvent) -> void:
	if _vehicle != null:
		return  # we're driving; the vehicle handles input
	if event.is_action_pressed("action"):  # E
		for v in get_tree().get_nodes_in_group("vehicle"):
			if v.has_method("enter_vehicle") and global_position.distance_to(v.global_position) < interact_distance:
				v.enter_vehicle(self)
				return

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0
	# Walk relative to the camera's yaw (orbit camera).
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := Vector3(input.x, 0.0, input.y)
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		dir = dir.rotated(Vector3.UP, cam.global_rotation.y)
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	move_and_slide()
