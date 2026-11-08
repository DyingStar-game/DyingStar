extends Node3D
## Shared PlanetTerrain subsystem. Physics is tick-command driven; camera/LOD
## never starts, retires or changes a physical patch. The authority installs
## canonical checkpoints. Only the client creates materials and cosmetic smoke.

const Core = preload("res://scenes/planet/lava/lava_fixed_core.gd")
const MAX_PATCHES := 2
var patches: Dictionary = {}
var server_mode := true
var planet_name := ""
var paused := false
var physics_pending := false
var smoke_enabled := true
var last_physics_ms := 0.0
var last_visual_ms := 0.0
var _overlay_head: ShaderMaterial
var _overlay_targets: Dictionary = {} # Weak references: never retain retired chunks.


func setup(data: PlanetData, authority_only: bool) -> void:
	planet_name = data.planet_name
	server_mode = authority_only
	set_process(not server_mode)


func install_patch(description: Dictionary) -> bool:
	var key := str(description.get("key", ""))
	if key.is_empty() or key.length() > 160 or str(description.get("planet", "")) != planet_name:
		return false
	if not patches.has(key) and patches.size() >= MAX_PATCHES:
		return false
	if not description.get("frame") is Transform3D or not description.get("checkpoint") is PackedByteArray:
		return false
	var frame: Transform3D = description.frame
	if not frame.origin.is_finite() or not frame.basis.is_finite() or absf(frame.basis.determinant() - 1.0) > 0.00001:
		return false
	var solver = Core.new() if server_mode else load("res://scenes/planet/lava/viscous_lava_solver.gd").new()
	if not solver.restore(description.checkpoint):
		return false
	remove_patch(key)
	var entry := {"solver": solver, "description": description.duplicate(true), "since_tick": 0.0,
		"holder": null, "surface": null, "mesh": null, "smoke": null, "overlay": null, "retired": false}
	if not server_mode:
		if solver.cleanup_complete():
			entry.retired = true
			solver.release_views()
		else: _create_visuals(entry)
	patches[key] = entry
	_refresh_terrain_overlays()
	return true


func _create_visuals(entry: Dictionary) -> void:
	entry.solver.presentation_enabled = true
	entry.solver.refresh_views()
	entry.retired = false
	var holder := Node3D.new()
	holder.name = "ViscousLava_%d" % patches.size()
	holder.transform = entry.description.frame
	add_child(holder)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/_universe/environment/terrain/viscous_lava.gdshader")
	var surface = load("res://scenes/planet/lava/viscous_lava_surface.gd").new()
	surface.configure(entry.solver, mat)
	var overlay := ShaderMaterial.new()
	overlay.shader = load("res://assets/_universe/environment/terrain/viscous_lava_ground.gdshader")
	overlay.set_shader_parameter("debug_field", "--lava-overlay-debug" in OS.get_cmdline_user_args())
	surface.add_material(overlay, entry.solver.cell_m)
	var mesh := MeshInstance3D.new()
	mesh.name = "LavaSurface"
	mesh.mesh = surface.mesh
	mesh.material_override = mat
	mesh.custom_aabb = surface.bounds
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(mesh)
	var smoke = load("res://scenes/planet/lava/lava_edge_smoke.gd").new()
	smoke.name = "LavaEdgeSmoke"
	holder.add_child(smoke)
	smoke.set_smoke_enabled(smoke_enabled)
	entry.merge({"holder": holder, "surface": surface, "mesh": mesh, "smoke": smoke, "overlay": overlay}, true)


func advance_patch(key: String, next_tick: int, commands: PackedInt64Array) -> bool:
	if not patches.has(key):
		return false
	var entry: Dictionary = patches[key]
	var started := Time.get_ticks_usec()
	if not entry.solver.advance_tick(next_tick, commands):
		return false
	last_physics_ms = (Time.get_ticks_usec() - started) / 1000.0
	publish_patch(key)
	return true


func publish_patch(key: String) -> void:
	var entry: Dictionary = patches[key]
	var started := Time.get_ticks_usec()
	if not server_mode:
		started = Time.get_ticks_usec()
		if entry.solver.cleanup_complete():
			if not entry.retired:
				_retire_visuals(entry)
				_refresh_terrain_overlays()
		elif entry.retired:
			_create_visuals(entry)
			_refresh_terrain_overlays()
		elif not entry.solver.visual_dirty.is_empty():
			entry.surface.publish(entry.solver, 0.1, true)
			entry.mesh.custom_aabb = entry.surface.bounds
			entry.since_tick = 0.0
		last_visual_ms = (Time.get_ticks_usec() - started) / 1000.0


func _retire_visuals(entry: Dictionary) -> void:
	if is_instance_valid(entry.holder):
		remove_child(entry.holder)
		entry.holder.queue_free()
	for key in ["holder", "surface", "mesh", "smoke", "overlay"]: entry[key] = null
	entry.retired = true
	entry.solver.release_views()


func remove_patch(key: String) -> void:
	if not patches.has(key):
		return
	var holder = patches[key].holder
	if is_instance_valid(holder):
		# Remove immediately so two replacements cannot draw at the same place.
		remove_child(holder)
		holder.queue_free()
	patches.erase(key)
	_refresh_terrain_overlays()


func clear_patches() -> void:
	for key: String in patches.keys():
		remove_patch(key)


func _process(delta: float) -> void:
	if server_mode:
		return
	for entry: Dictionary in patches.values():
		if entry.retired: continue
		var camera := get_viewport().get_camera_3d()
		if camera != null:
			entry.overlay.set_shader_parameter("patch_from_view", entry.holder.global_transform.affine_inverse() * camera.global_transform)
		if not paused:
			entry.since_tick = minf(float(entry.since_tick) + delta, 0.1)
			entry.surface.set_interpolation(float(entry.since_tick) * 10.0)
			if not physics_pending:
				entry.smoke.advance(delta, entry.solver)


func register_terrain_mesh(mesh: MeshInstance3D) -> void:
	if server_mode or _overlay_head == null or not is_instance_valid(mesh):
		return
	# Terrain geometry alone receives this pass; flying rocks, the player and
	# other foreground objects keep their ordinary depth occlusion.
	var chunk_box: AABB = mesh.transform * mesh.get_aabb()
	for entry: Dictionary in patches.values():
		if entry.retired: continue
		# Select by horizontal footprint. A coarse LOD may sit well ABOVE the
		# canonical bed; using the physical height range excludes exactly the
		# terrain triangles this presentation pass must cover.
		var local_box: AABB = entry.description.frame.affine_inverse() * chunk_box
		var extent: Vector3 = entry.surface.bounds.end
		var begin: Vector3 = entry.surface.bounds.position
		if local_box.position.x <= extent.x + 64.0 and local_box.end.x >= begin.x - 64.0 \
			and local_box.position.z <= extent.z + 64.0 and local_box.end.z >= begin.z - 64.0:
			if mesh.material_overlay == null or mesh.material_overlay == _overlay_head:
				mesh.material_overlay = _overlay_head
				_overlay_targets[mesh.get_instance_id()] = weakref(mesh)
				var forget := _forget_terrain_mesh.bind(mesh.get_instance_id())
				if not mesh.tree_exiting.is_connected(forget):
					mesh.tree_exiting.connect(forget, CONNECT_ONE_SHOT)
			return


func _forget_terrain_mesh(instance: int) -> void:
	_overlay_targets.erase(instance)


func _clear_terrain_overlays() -> void:
	for reference: WeakRef in _overlay_targets.values():
		var mesh = reference.get_ref()
		if is_instance_valid(mesh) and mesh.material_overlay == _overlay_head:
			mesh.material_overlay = null
	_overlay_targets.clear()


func _refresh_terrain_overlays() -> void:
	if server_mode:
		return
	_clear_terrain_overlays()
	_overlay_head = null
	var previous: ShaderMaterial
	for entry: Dictionary in patches.values():
		if entry.retired: continue
		entry.overlay.next_pass = null
		if previous != null:
			previous.next_pass = entry.overlay
		else:
			_overlay_head = entry.overlay
		previous = entry.overlay
	var terrain := get_parent()
	if terrain != null and "_active_chunks" in terrain:
		for chunk: Dictionary in terrain._active_chunks.values():
			var mesh: MeshInstance3D = chunk.get("mesh_instance")
			if is_instance_valid(mesh):
				register_terrain_mesh(mesh)


func _exit_tree() -> void:
	_clear_terrain_overlays()


func set_smoke(enabled: bool) -> void:
	smoke_enabled = enabled
	for entry: Dictionary in patches.values():
		if entry.smoke != null:
			entry.smoke.set_smoke_enabled(enabled)
