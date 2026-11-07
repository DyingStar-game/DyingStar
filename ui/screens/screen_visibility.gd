class_name ScreenVisibility
extends RefCounted

## Whether anyone can see a screen of the world (ADR 0027): a screen works -- animates, redraws, renders
## its viewport -- only when the camera is near it and has it in view. The one test every world screen
## asks, so they all answer the same way.

## How often (s) a screen asks; each starts at its own random moment so a town's do not ask together.
const CHECK_S: float = 0.25


## Whether [param camera] is within [param range_m] of [param box] (a world AABB) and has some of it
## in view. A null camera (the dedicated server) sees nothing.
static func sees_box(camera: Camera3D, box: AABB, range_m: float) -> bool:
	if camera == null:
		return false
	var centre: Vector3 = box.get_center()
	var reach: float = range_m + box.size.length() * 0.5
	if camera.global_position.distance_squared_to(centre) > reach * reach:
		return false
	if camera.is_position_in_frustum(centre):
		return true
	for i: int in range(8):
		if camera.is_position_in_frustum(box.get_endpoint(i)):
			return true
	return false


## Whether [param camera] is within [param range_m] of [param at] and has it in view.
static func sees(camera: Camera3D, at: Vector3, range_m: float) -> bool:
	return sees_box(camera, AABB(at, Vector3.ZERO), range_m)
