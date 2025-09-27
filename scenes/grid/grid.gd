class_name PhysicsGrid

extends Area3D

# TODO: implement translation/rotation of nodes detected by area based on parent

# func _physics_process(delta: float) -> void:
# 	gravity_direction = -global_basis.y


#this fix gravity when transform the node (local direction instead of worldwide gravity definiting)
@export var local_gravity_direction := Vector3(0, -1, 0)

func _notification(what: int):
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		gravity_direction = global_transform.basis * local_gravity_direction
