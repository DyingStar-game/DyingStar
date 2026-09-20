@tool
extends StaticBody3D


@onready var animated_axis: Node3D = %"Animated Axis"
@onready var animated_axis_visual: MeshInstance3D = %"Animated Axis Visual"
@onready var axis_collider: CollisionShape3D = %"Collider Axis"
@onready var wheel_visual: MeshInstance3D = %"Wheel Visual"


const ANIMATED_AXIS_MIN_LENGTH: float = 0.55
const AXIS_COLLIDER_MIN_LENGTH: float = 1.1
const AXIS_COLLIDER_DEFAULT_Z: float = 1.7


func _set_axis_length(length: float) -> void:
	var new_length: float = ANIMATED_AXIS_MIN_LENGTH + length
	var new_collider_length: float = AXIS_COLLIDER_MIN_LENGTH + length
	
	if animated_axis_visual.mesh and animated_axis_visual.mesh is CylinderMesh:
		if not animated_axis_visual.mesh.resource_local_to_scene:
			animated_axis_visual.mesh = animated_axis_visual.mesh.duplicate()
			animated_axis_visual.mesh.resource_local_to_scene = true
		
		animated_axis_visual.mesh.height = new_length
		animated_axis_visual.position.z = (new_length / 2.0)
	
	if axis_collider and axis_collider.shape and axis_collider.shape is CylinderShape3D:
		axis_collider.shape.height = new_collider_length
		axis_collider.position.z = ((new_collider_length + AXIS_COLLIDER_DEFAULT_Z) / 2.0)
	
	if wheel_visual:
		wheel_visual.position.z = new_length


func _update_animated_axis_rotation(platform_progress_ratio: float, descent_depth: float) -> void:
	var distance_traveled: float = (platform_progress_ratio / 100.0) * descent_depth
	
	var axis_radius: float = 1.0
	if animated_axis_visual.mesh and animated_axis_visual.mesh is CylinderMesh:
		axis_radius = animated_axis_visual.mesh.top_radius if animated_axis_visual.mesh.top_radius > 0.001 else axis_radius
	
	var axis_rotation_angle: float = distance_traveled / (axis_radius * 3.0)
	animated_axis.rotation.z = axis_rotation_angle
