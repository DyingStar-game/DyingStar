class_name Box4m

extends RigidBody3D

@export var inside_space: World3D

var type_name = "box4m"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

func _ready() -> void:
	$Area3D.body_entered.connect(_on_box_entered)
	$Area3D.body_exited.connect(_on_box_exited)

	global_position = spawn_position
	global_rotation = spawn_rotation

func _on_box_entered(body: Node3D):
	if body.is_in_group("containable"):
		if not body.is_inside_box4m:
			body.set_collision_layer_value(1, false)
			body.set_collision_layer_value(2, true)
			body.set_collision_mask_value(1, false)
			body.set_collision_mask_value(2, true)
			body.is_inside_box4m = true

func _on_box_exited(body: Node3D):
	if body.is_in_group("containable"):
		if body.is_inside_box4m:
			body.set_collision_layer_value(2, false)
			body.set_collision_layer_value(1, true)
			body.set_collision_mask_value(2, false)
			body.set_collision_mask_value(1, true)
			body.is_inside_box4m = false
