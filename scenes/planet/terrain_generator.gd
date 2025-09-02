@tool
extends Node3D
class_name QuadtreeNode

## Based on: https://github.com/stefsdev/ProcPlanetLOD

@export var planet: PlanetTerrain

var focus_positions_last = []
var focus_positions: Array[Vector3] = []

# Quadtree specific properties
@export var normal : Vector3

var camera_dir: Vector3
var last_cam_dir: Vector3

var axisA: Vector3
var axisB: Vector3

var skirt_indices := 2
var chunk_resolution := 60
var max_chunk_depth := 8

var chunks_list = {}
var chunks_list_current = {}
# collision shape for chunks
var chunks_col_list = {}
# chunks that do not have a meshinstance yet
var chunks_generating = {}

var update_thread: Thread
var semaphore: Semaphore
var mutex: Mutex
var should_exit = false

var my_name: String = ""
var is_visible_status: bool = true

var run_serverside = false

# Placeholder for the quadtree structure
var quadtree: QuadtreeChunk

# Define a Quadtree chunk class
class QuadtreeChunk:
	var bounds: AABB
	var children = []
	var depth: int
	var max_chunk_depth: int
	var identifier: String
	var chunk_name: String
	
	var planet: PlanetTerrain
	var face_origin: Vector3
	var axisA: Vector3
	var axisB: Vector3
	
	func _init(_bounds: AABB, _depth: int, _max_chunk_depth: int, _planet: PlanetTerrain, _face_origin: Vector3, _axisA: Vector3, _axisB: Vector3, _name: String):
		bounds = _bounds
		depth = _depth
		max_chunk_depth = _max_chunk_depth
		identifier = generate_identifier()
		chunk_name = _name
		planet = _planet
		face_origin = _face_origin
		axisA = _axisA
		axisB = _axisB

	func generate_identifier() -> String:
		# Generate a unique identifier for the chunk based on bounds and depth
		return "%s_%s_%d" % [bounds.position, bounds.size, depth]
	
	
	func within_lod_distance(lod_centers: Array[Vector3], run_serverside: bool, center_local_3d: Vector3) -> bool:
		for pos: Vector3 in lod_centers:
			var h := planet.get_height(center_local_3d.normalized())
			var distance := h.distance_to(pos)
			
			if distance <= planet.radius * bounds.size.x * 0.7:
			#if distance <= planet.radius * bounds.size.x * 0.35:
				return true
		
		return false

	func subdivide(lod_centers: Array[Vector3], run_serverside: bool):
		# Calculate new bounds for children
		var half_size := bounds.size.x * 0.5
		var quarter_size := bounds.size.x * 0.25
		var half_extents := Vector3(half_size, half_size, half_size)
		
		var child_offsets: Array[Vector2] = [
			Vector2(-quarter_size, -quarter_size),
			Vector2(quarter_size, -quarter_size),
			Vector2(-quarter_size, quarter_size),
			Vector2(quarter_size, quarter_size)
		]
		

		for offset: Vector2 in child_offsets:
			var child_pos_2d := Vector2(bounds.position.x, bounds.position.z) + offset
			var center_local_3d := face_origin + child_pos_2d.x * axisA + child_pos_2d.y * axisB
			
			var child_number: int = children.size()
			if depth < max_chunk_depth and within_lod_distance(lod_centers, run_serverside, center_local_3d):
				var child_bounds := AABB(Vector3(child_pos_2d.x, 0, child_pos_2d.y), half_extents)
				var new_child := QuadtreeChunk.new(child_bounds, depth + 1, max_chunk_depth, planet, face_origin, axisA, axisB, chunk_name+"_"+str(child_number))
				children.append(new_child)
				
				new_child.subdivide(lod_centers, run_serverside)
			else:
				var child_bounds := AABB(Vector3(child_pos_2d.x, 0, child_pos_2d.y) - Vector3(quarter_size, quarter_size, quarter_size), half_extents)
				var new_child := QuadtreeChunk.new(child_bounds, depth + 1, max_chunk_depth, planet, face_origin, axisA, axisB, chunk_name+"_"+str(child_number))
				children.append(new_child)

func visualize_quadtree(chunk: QuadtreeChunk):
	
	var at_col_depth = chunk.depth == max_chunk_depth
	
	# Generate a MeshInstance for each chunk
	if not chunk.children or at_col_depth:
	
		chunks_list_current[chunk.identifier] = true
		
		#if chunk.identifier already exists leave it
		if chunks_generating.has(chunk.identifier):
			return
		
		var chunk_res = 0 if run_serverside and chunk.depth < max_chunk_depth - 1 else chunk_resolution
		
		var size := chunk.bounds.size.x
		var offset := chunk.bounds.position
		var resolution: int = chunk_resolution + skirt_indices
		
		if at_col_depth:
			resolution -= 20
		
		var vertex_array := PackedVector3Array()
		var normal_array := PackedVector3Array()
		var index_array := PackedInt32Array()
		
		# Pre-allocate indices (we know exact count)
		var num_cells := (resolution - 1)
		index_array.resize(num_cells * num_cells * 6)

		# Build vertices & normals (initialized zero)
		vertex_array.resize(resolution * resolution)
		normal_array.resize(resolution * resolution)
		
		var chunk_global_pos := (normal + offset.x * axisA + offset.z * axisB).normalized() * planet.radius
		
		var tri_idx: int = 0
		for y in range(resolution):
			for x in range(resolution):
				var edge = (x == 0 or x == resolution - 1 or y == 0 or y == resolution - 1)
				var i := x + y * resolution
				var percent := Vector2(x, y) / float(resolution - skirt_indices - 1)
				var local := Vector2(offset.x, offset.z) + percent * size
				var point_on_plane = normal + local.x * axisA + local.y * axisB
				
				# Project onto sphere and apply height
				var sphere_pos := planet.get_height(point_on_plane.normalized())
				
				# calculate offset to lower the vertices that are on the edge of the chunk
				var lod_offset := point_on_plane.normalized() * 0.01 if edge else Vector3.ZERO
				vertex_array[i] = sphere_pos - chunk_global_pos - lod_offset
				normal_array[i] = Vector3.ZERO
				
				# Track height extremes
				var length := sphere_pos.length()
				planet.min_height = min(planet.min_height, length)
				planet.max_height = max(planet.max_height, length)
				
				# Create two triangles per cell
				if x < resolution - 1 and y < resolution - 1:
					# Triangle 1
					index_array[tri_idx]     = i
					index_array[tri_idx + 1] = i + resolution
					index_array[tri_idx + 2] = i + resolution + 1
					# Triangle 2
					index_array[tri_idx + 3] = i
					index_array[tri_idx + 4] = i + resolution + 1
					index_array[tri_idx + 5] = i + 1
					tri_idx += 6
		
		# Calculate smooth normals
		for t in range(0, index_array.size(), 3):
			var a := index_array[t]
			var b := index_array[t + 1]
			var c := index_array[t + 2]
			var v0 := vertex_array[a]
			var v1 := vertex_array[b]
			var v2 := vertex_array[c]
			var face_normal := -(v1 - v0).cross(v2 - v0).normalized()
			
			normal_array[a] += face_normal
			normal_array[b] += face_normal
			normal_array[c] += face_normal
			
		# Normalize vertex normals
		for i in range(normal_array.size()):
			normal_array[i] = normal_array[i].normalized()
		
		# Prepare mesh arrays
		var arrays = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertex_array
		arrays[Mesh.ARRAY_NORMAL] = normal_array
		arrays[Mesh.ARRAY_INDEX] = index_array
		
		if not at_col_depth or not chunk.children:
			chunks_generating[chunk.identifier] = true
		
		create_mesh_and_collision.call_deferred(arrays, chunk, chunk_global_pos, not chunk.children.is_empty())
	
	# Recursively visualize children chunks
	for child in chunk.children:
		visualize_quadtree(child)

# this is run in the next process frame, not in the terrain generation thread
func create_mesh_and_collision(arrays: Array, chunk: QuadtreeChunk, chunk_pos: Vector3, has_children: bool):
	#prints("generating mesh for chunk", chunk.identifier)
	# Create and instance mesh
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	# generate collisions
	if chunk.depth == max_chunk_depth and not Engine.is_editor_hint():
		if !chunks_col_list.has(chunk.identifier):
			#print("generating collision", chunk.identifier, mesh.get_surface_count())
			add_collision_shape(chunk.identifier, mesh, chunk_pos)
		else:
			update_collision(chunk.identifier, mesh)
		# dont generate the mesh if there are chunk children
	
	if has_children:
		return
	
	if not run_serverside:
		var mi = MeshInstance3D.new()
		mi.position = chunk_pos
		mi.mesh = mesh
		mi.name = "Mesh_" + chunk.chunk_name
		mi.material_override = planet.terrain_material
		mi.set_instance_shader_parameter("offset_pos", chunk_pos)
		
		if planet.terrain_material is ShaderMaterial:
			var mat = planet.terrain_material as ShaderMaterial
			
			#(material as ShaderMaterial).set_shader_parameter("h_min", planet.min_height)
			#(material as ShaderMaterial).set_shader_parameter("h_max", planet.max_height)
		
			add_child(mi)
		
			#add this chunk to chunk list
			chunks_list[chunk.identifier] = mi

func update_collision(id: String, _mesh: ArrayMesh):
	if is_instance_valid(chunks_col_list[id]):
		var col = chunks_col_list[id] as CollisionShape3D
		col.disabled = false
	#prints("update shape for chunk", id)

func add_collision_shape(id: String, mesh: ArrayMesh, chunk_pos: Vector3):
	var _t =  Time.get_ticks_msec()
	#staticbody.position = mesh.get_aabb().get_center()
	var collision_shape = CollisionShape3D.new()
	collision_shape.position = chunk_pos
	collision_shape.name = "ChunkColShape"
	collision_shape.shape = mesh.create_trimesh_shape()
	planet.add_child(collision_shape, true)
	
	#logmsg("duration: %d ms" % (t - Time.get_ticks_msec()))
#
	#logmsg("add static body for chunk %s faces %d" % [id, (collision_shape.shape as ConcavePolygonShape3D).get_faces().size()])

	chunks_col_list[id] = collision_shape


func logmsg(msg: String):
	if Engine.is_editor_hint(): return
	Globals.log.call_deferred(msg)

func _enter_tree() -> void:
	update_thread = Thread.new()
	semaphore = Semaphore.new()
	mutex = Mutex.new()

func _ready():
	
	should_exit = false
	my_name = name
	is_visible_status = visible
	
	run_serverside = not Engine.is_editor_hint() and multiplayer.is_server()
	
	# Clear existing children
	for child in get_children():
		remove_child(child)
		child.queue_free()
	
	var chunk_parent: Node = get_parent()
	if not chunk_parent is PlanetTerrain: return
	
	planet = chunk_parent
	
	if not planet.terrain_settings:
		push_error("Oops il n'y a pas de terrain_settings dans planet_terrain!")
		return
	
	var thread_name: String = name + "_thread"
	update_thread.start(Callable(self, "update_process").bind(thread_name))
	
	axisA = Vector3(normal.y, normal.z, normal.x).normalized()
	axisB = normal.cross(axisA).normalized()
	
	update_chunks.call_deferred()
	
	planet.regenerate.connect(func(resolution):
		chunk_resolution = resolution
		for chunk in chunks_list:
			chunks_list[chunk].queue_free()
		
		chunks_list.clear()
		chunks_generating.clear()
		if is_visible_status:
			update_chunks.call_deferred()
	)

func _exit_tree() -> void:
	if update_thread.is_started():
		mutex.lock()
		should_exit = true # Protect with Mutex.
		mutex.unlock()
		
		semaphore.post()
		update_thread.wait_to_finish()

func update_process(thread_name: String):
	while true:
		semaphore.wait() # Wait until posted.
		
		mutex.lock()
		var must_exit = should_exit # Protect with Mutex.
		mutex.unlock()
		
		if must_exit:
			break
		
		call_deferred("_get_visibility", self)
		
		semaphore.wait()
		
		mutex.lock()
		var node_is_visible = is_visible_status
		mutex.unlock()
		
		mutex.lock()
		var positions = []
		for pos in focus_positions:
			positions.push_back(floor(pos))
		focus_positions_last = positions
		mutex.unlock()
		
		if node_is_visible:
			update_chunks()

func positions_changed() -> bool:
	if focus_positions.size() != focus_positions_last.size():
		return true
	
	for i in focus_positions.size():
		if focus_positions[i] != focus_positions_last[i]:
			if floor(focus_positions[i]) != focus_positions_last[i]:
				return true
	
	return false

func transform_positions() -> Array[Vector3]:
	var transformed_positions: Array[Vector3] = []
	for pos in planet.focus_positions:
		transformed_positions.push_back(global_transform.inverse() * pos)
	return transformed_positions

func _process(_delta):
	#### EMPECHE LES COLLISIONS COTES SERVEUR
	if Engine.is_editor_hint():
		if chunks_list.is_empty():
			return
	
	var current_focus_positions = transform_positions()
	
	var positions_changed_flag = false
	if focus_positions.size() != current_focus_positions.size():
		#print_rich("\t[color=green]positions_changed_flag = true[/color]")
		positions_changed_flag = true
	else:
		for i in range(focus_positions.size()):
			if focus_positions[i] != current_focus_positions[i]:
				positions_changed_flag = true
				break
	
	if positions_changed_flag:
		mutex.lock()
		focus_positions = current_focus_positions
		mutex.unlock()
		semaphore.post()

func update_chunks():
	# Initialize the quadtree by creating the root chunk
	var bounds = AABB(Vector3(0, 0, 0), Vector3(2,2,2))
	var chunk_name: String = "Chunk_" + str(0)
	quadtree = QuadtreeChunk.new(bounds, 0, max_chunk_depth, planet, normal, axisA, axisB, chunk_name)
	# Start the subdivision process
	quadtree.subdivide(focus_positions.duplicate(), run_serverside)
	
	chunks_list_current = {}
	
	# Create a visual representation
	var t = Time.get_ticks_msec()
	visualize_quadtree(quadtree)
	#prints(quadtree, "quadtree visualize took: ", Time.get_ticks_msec() - t, "ms")
	#prints("deleting chunk", chunks_list_current)
	
	#remove any old unused chunks
	var chunks_to_remove = []
	for chunk_id in chunks_list:
		if not chunks_list_current.has(chunk_id):
			chunks_to_remove.append(chunk_id)
	
	for chunk_id in chunks_to_remove:
		if chunk_id in chunks_list:
			chunks_list[chunk_id].queue_free.call_deferred()
			chunks_list.erase(chunk_id)
			chunks_generating.erase(chunk_id)
	
	cleanup_collisions.call_deferred()

func cleanup_collisions():
	for chunkid: String in chunks_col_list:
		if is_instance_valid(chunks_col_list[chunkid]):
			var col = chunks_col_list[chunkid] as CollisionShape3D
			if any_player_near(col, 400):
				col.disabled = true
			elif not any_player_near(col):
				col.queue_free()
				chunks_col_list.erase(chunkid)

func any_player_near(shape: CollisionShape3D, distance = 1000):
	for pos: Vector3 in focus_positions:
		if pos.distance_squared_to(shape.position) < distance*distance:
			return true
	return false

func disable_col(chunk_id):
	if chunk_id in chunks_col_list:
		chunks_col_list[chunk_id].disabled = true

func _get_visibility(called_node) -> void:
	mutex.lock()
	is_visible_status = visible
	mutex.unlock()
	semaphore.post()
