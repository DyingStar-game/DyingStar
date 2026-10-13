@tool
extends Path3D

@export_group("Cable Settings")
@export var radius: float = 0.05:
	set(value):
		radius = max(0.01, value)
		_queue_update()

@export var radial_steps: int = 8:
	set(value):
		radial_steps = max(3, value)
		_queue_update()

@export var uv_length_scale: float = 1.0:
	set(value):
		uv_length_scale = max(0.01, value)
		_queue_update()

@export var cable_material: Material:
	set(value):
		cable_material = value
		if _mesh_instance:
			_mesh_instance.material_override = cable_material

var _mesh_instance: MeshInstance3D
var _update_queued: bool = false

func _ready() -> void:
	if not has_node("CableMesh"):
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "CableMesh"
		add_child(_mesh_instance)
		
		if Engine.is_editor_hint() and owner == null:
			_mesh_instance.owner = get_tree().edited_scene_root
		elif owner != null:
			_mesh_instance.owner = owner
	else:
		_mesh_instance = get_node("CableMesh")
		
	_mesh_instance.material_override = cable_material
	_connect_curve_signal()
	_queue_update()

func _set(property: StringName, value: Variant) -> bool:
	
	if property == "curve":
		_connect_curve_signal()
		_queue_update()
	return false

func _connect_curve_signal() -> void:
	if curve and not curve.changed.is_connected(_queue_update):
		curve.changed.connect(_queue_update)

func _queue_update() -> void:
	
	if not _update_queued:
		_update_queued = true
		call_deferred("_generate_mesh")

func _generate_mesh() -> void:
	_update_queued = false
	
	if not curve or curve.get_baked_length() <= 0.0:
		if _mesh_instance:
			_mesh_instance.mesh = null
		return

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var length = curve.get_baked_length()
	
	var interval = curve.bake_interval 
	var ring_count = int(ceil(length / interval)) + 1
	
	for i in range(ring_count):
		var offset = min(i * interval, length)
		var transform = curve.sample_baked_with_rotation(offset, true, true)
		
		for j in range(radial_steps + 1):
			var angle = (float(j) / radial_steps) * TAU
			
			var local_pos = Vector3(cos(angle) * radius, sin(angle) * radius, 0.0)
			var normal = local_pos.normalized()
			
			var vertex_pos = transform * local_pos
			var vertex_normal = transform.basis * normal
			
			var uv = Vector2(float(j) / radial_steps, (offset / uv_length_scale))
			
			st.set_normal(vertex_normal)
			st.set_uv(uv)
			st.add_vertex(vertex_pos)
			
		if i > 0:
			for j in range(radial_steps):
				var current_ring = i * (radial_steps + 1)
				var prev_ring = (i - 1) * (radial_steps + 1)
				
				var v0 = prev_ring + j
				var v1 = current_ring + j
				var v2 = current_ring + j + 1
				var v3 = prev_ring + j + 1
				
				# Triangle 1
				st.add_index(v0)
				st.add_index(v2)
				st.add_index(v1)
				
				# Triangle 2
				st.add_index(v0)
				st.add_index(v3)
				st.add_index(v2)
	
	var array_mesh = _mesh_instance.mesh as ArrayMesh
	if array_mesh:
		array_mesh.clear_surfaces()
		
	_mesh_instance.mesh = st.commit(array_mesh)
