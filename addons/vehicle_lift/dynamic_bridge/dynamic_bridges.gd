@tool
extends Node3D


const BRIDGE_COLLIDER_BASE_LENGTH: float = 0.75


var _right_bridge: StaticBody3D
var _left_bridge: StaticBody3D

var _last_z_offset: float = 0.0

var _dynamic_right_bridge_visual: MeshInstance3D
var _dynamic_left_bridge_visual: MeshInstance3D
var _dynamic_bridge_mesh: ArrayMesh
var _moving_indices: Array[PackedInt32Array] = []
var _central_indices: Array[PackedInt32Array] = []

var _dynamic_right_bridge_collider_01: CollisionShape3D
var _dynamic_right_bridge_collider_02: CollisionShape3D
var _dynamic_left_bridge_collider_01: CollisionShape3D
var _dynamic_left_bridge_collider_02: CollisionShape3D

var _dynamic_bridge_collider_shape_01: Shape3D
var _dynamic_bridge_collider_shape_02: Shape3D


@export_range(0.0, 4.0, 0.01, "suffix:m") var z_offset: float = 0.0:
	set(value):
		if value != z_offset:
			z_offset = max(0.0, value)
			
			update_length(z_offset)
			update_collider_position(z_offset)


func _ready() -> void:
	_right_bridge = get_node_or_null("Right Bridge")
	_left_bridge = get_node_or_null("Left Bridge")
	
	if not _right_bridge or not _left_bridge:
		return
	
	_dynamic_right_bridge_visual = _right_bridge.get_node_or_null("Visual")
	_dynamic_left_bridge_visual = _left_bridge.get_node_or_null("Visual")
	if not _dynamic_right_bridge_visual or not _dynamic_left_bridge_visual or not _dynamic_right_bridge_visual.mesh:
		return
	
	_dynamic_bridge_mesh = _dynamic_right_bridge_visual.mesh
	
	_dynamic_right_bridge_collider_01 = _right_bridge.get_node_or_null("Collider 01")
	_dynamic_right_bridge_collider_02 = _right_bridge.get_node_or_null("Collider 02")
	_dynamic_left_bridge_collider_01 = _left_bridge.get_node_or_null("Collider 01")
	_dynamic_left_bridge_collider_02 = _left_bridge.get_node_or_null("Collider 02")
	if not _dynamic_right_bridge_collider_01 or not _dynamic_right_bridge_collider_02 or not _dynamic_left_bridge_collider_01 or not _dynamic_left_bridge_collider_02 or not _dynamic_right_bridge_collider_01.shape or not _dynamic_right_bridge_collider_02.shape:
		return
	
	_dynamic_bridge_collider_shape_01 = _dynamic_right_bridge_collider_01.shape
	_dynamic_bridge_collider_shape_02 = _dynamic_right_bridge_collider_02.shape
	
	categorize_vertices()


func categorize_vertices() -> void:
	_moving_indices.clear()
	_central_indices.clear()
	
	
	_dynamic_bridge_mesh.shadow_mesh = null
	
	for surface_index in range(_dynamic_bridge_mesh.get_surface_count()):
		var moving_indices_for_this_surface = PackedInt32Array()
		var central_indices_for_this_surface = PackedInt32Array()
		
		var vertices: PackedVector3Array = _dynamic_bridge_mesh.surface_get_arrays(surface_index)[Mesh.ARRAY_VERTEX]
		
		for i in range(vertices.size()):
			var current_z = vertices[i].z
			
			var base_z_if_central: float = current_z - (z_offset / 2.0)
			var base_z_if_moving: float = current_z - z_offset
			
			# Marge de 0.1
			if abs(base_z_if_central - 0.38) <= 0.1:
				central_indices_for_this_surface.append(i)
			elif abs(base_z_if_moving - 0.72) <= 0.1:
				moving_indices_for_this_surface.append(i)
		
		_moving_indices.append(moving_indices_for_this_surface)
		_central_indices.append(central_indices_for_this_surface)


func update_length(z_offset: float) -> void:
	var delta: float = z_offset - _last_z_offset
	z_offset = max(0.0, z_offset)
	_last_z_offset = z_offset
	
	if not _dynamic_bridge_mesh:
		return
	
	## INFO {material, format, primitive, arrays}
	var new_surfaces: Array[Dictionary] = []
	
	for surface_index in range(_dynamic_bridge_mesh.get_surface_count()):
		var material: Material = _dynamic_right_bridge_visual.get_active_material(surface_index)
		var format: int = _dynamic_bridge_mesh.surface_get_format(surface_index)
		var primitive_type: int = _dynamic_bridge_mesh.surface_get_primitive_type(surface_index)
		
		var arrays = _dynamic_bridge_mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		
		for i in _moving_indices[surface_index]:
			vertices[i].z += delta
		
		for i in _central_indices[surface_index]:
			vertices[i].z += delta / 2.0
		
		arrays[Mesh.ARRAY_VERTEX] = vertices
		new_surfaces.append({"material" : material, "format": format, "primitive_type": primitive_type, "arrays" : arrays})
	
	_dynamic_bridge_mesh.clear_surfaces()
	for surface_index in range(new_surfaces.size()):
		_dynamic_bridge_mesh.add_surface_from_arrays(new_surfaces[surface_index].primitive_type, new_surfaces[surface_index].arrays, [], {}, new_surfaces[surface_index].format)
		_dynamic_right_bridge_visual.set_surface_override_material(surface_index, new_surfaces[surface_index].material)
		_dynamic_left_bridge_visual.set_surface_override_material(surface_index, new_surfaces[surface_index].material)
	
	_dynamic_bridge_collider_shape_01.size.z = BRIDGE_COLLIDER_BASE_LENGTH + z_offset
	_dynamic_bridge_collider_shape_02.size.z = BRIDGE_COLLIDER_BASE_LENGTH + z_offset


func update_collider_position(z_offset: float) -> void:
	if not _dynamic_right_bridge_collider_01 or not _dynamic_right_bridge_collider_02 or not _dynamic_left_bridge_collider_01 or not _dynamic_left_bridge_collider_02:
		return
	
	_dynamic_right_bridge_collider_01.position.z = (BRIDGE_COLLIDER_BASE_LENGTH + z_offset) / 2.0
	_dynamic_right_bridge_collider_02.position.z = (BRIDGE_COLLIDER_BASE_LENGTH + z_offset) / 2.0
	_dynamic_left_bridge_collider_01.position.z = (BRIDGE_COLLIDER_BASE_LENGTH + z_offset) / 2.0
	_dynamic_left_bridge_collider_02.position.z = (BRIDGE_COLLIDER_BASE_LENGTH + z_offset) / 2.0
