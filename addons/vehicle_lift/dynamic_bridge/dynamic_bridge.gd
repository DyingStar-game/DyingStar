@tool
extends StaticBody3D


const BRIDGE_COLLIDER_BASE_LENGTH: float = 0.75


var _dynamic_bridge_visual: MeshInstance3D
var _dynamic_bridge_collider: CollisionShape3D

var _is_initialized: bool = false
var _last_z_offset: float = 0.0

var _moving_indices: Array[PackedInt32Array] = []
var _central_indices: Array[PackedInt32Array] = []

@export_range(0.0, 4.0, 0.01, "suffix:m") var z_offset: float = 0.0:
	set(value):
		if value != z_offset and _is_initialized:
			var delta: float = value - z_offset
			z_offset = max(0.0, value)
			
			update_length(z_offset)
			update_collider_position(z_offset)


func _ready() -> void:
	print_rich("dynamic_bridge _ready")
	_dynamic_bridge_visual = get_node_or_null("Visual")
	_dynamic_bridge_collider = get_node_or_null("Collider")
	
	if not _dynamic_bridge_visual or not _dynamic_bridge_visual.mesh:
		return
	
	if Engine.is_editor_hint():
		if self == get_tree().edited_scene_root:
			_dynamic_bridge_visual.mesh = _dynamic_bridge_visual.mesh.duplicate(true)
			categorize_vertices()


func categorize_vertices() -> void:
	_moving_indices.clear()
	_central_indices.clear()
	
	_dynamic_bridge_visual.mesh.shadow_mesh = null
	
	for surface_index in range(_dynamic_bridge_visual.mesh.get_surface_count()):
		var moving_indices_for_this_surface = PackedInt32Array()
		var central_indices_for_this_surface = PackedInt32Array()
		
		var vertices: PackedVector3Array = _dynamic_bridge_visual.mesh.surface_get_arrays(surface_index)[Mesh.ARRAY_VERTEX]
		
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
	
	
	_is_initialized = true


func update_length(z_offset: float) -> void:
	var delta: float = z_offset - _last_z_offset
	z_offset = max(0.0, z_offset)
	_last_z_offset = z_offset
	
	if not _dynamic_bridge_visual or not _dynamic_bridge_visual.mesh:
		return
	
	## INFO {material, format, primitive, arrays}
	var new_surfaces: Array[Dictionary] = []
	
	for surface_index in range(_dynamic_bridge_visual.mesh.get_surface_count()):
		var material: Material = _dynamic_bridge_visual.get_active_material(surface_index)
		var format: int = _dynamic_bridge_visual.mesh.surface_get_format(surface_index)
		var primitive_type: int = _dynamic_bridge_visual.mesh.surface_get_primitive_type(surface_index)
		
		var arrays = _dynamic_bridge_visual.mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		
		for i in _moving_indices[surface_index]:
			vertices[i].z += delta
		
		for i in _central_indices[surface_index]:
			vertices[i].z += delta / 2.0
		
		arrays[Mesh.ARRAY_VERTEX] = vertices
		new_surfaces.append({"material" : material, "format": format, "primitive_type": primitive_type, "arrays" : arrays})
	
	_dynamic_bridge_visual.mesh.clear_surfaces()
	for surface_index in range(new_surfaces.size()):
		_dynamic_bridge_visual.mesh.add_surface_from_arrays(new_surfaces[surface_index].primitive_type, new_surfaces[surface_index].arrays, [], {}, new_surfaces[surface_index].format)
		_dynamic_bridge_visual.set_surface_override_material(surface_index, new_surfaces[surface_index].material)
	
	if not _dynamic_bridge_collider or not _dynamic_bridge_collider.shape:
		return
	
	_dynamic_bridge_collider.shape.size.z = BRIDGE_COLLIDER_BASE_LENGTH + z_offset


func update_collider_position(z_offset: float) -> void:
	if not _dynamic_bridge_collider:
		return
	
	_dynamic_bridge_collider.position.z = (BRIDGE_COLLIDER_BASE_LENGTH + z_offset) / 2.0


func get_mesh() -> ArrayMesh:
	if not _dynamic_bridge_visual or not _dynamic_bridge_visual.mesh:
		return null
	else:
		return _dynamic_bridge_visual.mesh


func set_mesh(shared_mesh: ArrayMesh) -> Error:
	if not _dynamic_bridge_visual:
		return ERR_DOES_NOT_EXIST
	else:
		_dynamic_bridge_visual.mesh = shared_mesh
		return OK


func get_collider_shape() -> BoxShape3D:
	if not _dynamic_bridge_collider or not _dynamic_bridge_collider.shape:
		return null
	else:
		return _dynamic_bridge_collider.shape


func set_collider_shape(shape: BoxShape3D) -> Error:
	if not _dynamic_bridge_collider:
		return ERR_DOES_NOT_EXIST
	else:
		_dynamic_bridge_collider.shape = shape
		return OK
