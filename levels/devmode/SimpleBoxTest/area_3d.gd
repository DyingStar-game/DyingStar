extends Area3D

## Gravity direction in this area's LOCAL space: rotated into world space and applied as
## gravity_direction whenever the area's transform changes, so gravity turns with the box.
@export var local_gravity_direction := Vector3(0, -1, 0)

func _notification(what: int):
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		gravity_direction = global_transform.basis * local_gravity_direction
