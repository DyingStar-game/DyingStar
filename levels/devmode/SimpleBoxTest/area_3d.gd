extends Area3D

@export var local_gravity_direction := Vector3(0, -1, 0)

func _notification(what: int):
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		gravity_direction = global_transform.basis * local_gravity_direction
