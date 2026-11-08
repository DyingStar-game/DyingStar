extends RefCounted
## Fixed mesh + two reusable GPU snapshots. Interpolation never modifies the
## physical solver. One physics tick of presentation latency avoids prediction.

var mesh: ArrayMesh
var bounds: AABB
var publications := 0
var mesh_builds := 0
var phases := PackedVector2Array()
var _state := PackedFloat32Array()
var _phase := PackedFloat32Array()
var _state_textures: Array[ImageTexture] = []
var _phase_textures: Array[ImageTexture] = []
var _state_image: Image
var _phase_image: Image
var _material: ShaderMaterial
var _materials: Array[ShaderMaterial] = []
var _alpha := 1.0
var _geometry := {}
var _current := 0
var _nx := 0
var _nz := 0
var _minimum := 0.0
var _maximum := 0.0


func configure(sim, material: ShaderMaterial) -> void:
	var centres := PackedFloat32Array()
	centres.resize(256); centres.fill(0.0)
	if sim.geometry_mode == 1:
		for r in sim.height: centres[r] = sim.radial_centres[r]
	_geometry = {"polar_geometry": sim.geometry_mode == 1, "radial_count": sim.height,
		"radial_centres": centres, "field_radius": sim.radial_edges_mm[-1] / 1000.0 if sim.geometry_mode == 1 else 0.0}
	_material = material
	for key in _geometry: material.set_shader_parameter(key, _geometry[key])
	_materials = [material]
	_nx = sim.width
	_nz = sim.height
	_current = 0
	publications = 0
	phases.resize(_nx * _nz)
	phases.fill(Vector2.ZERO)
	_state.resize(_nx * _nz * 4)
	_state.fill(0.0)
	_minimum = INF
	_maximum = -INF
	for i in _nx * _nz:
		_state[i * 4 + 2] = 1.0
		_state[i * 4 + 3] = sim.bed[i]
		_minimum = minf(_minimum, sim.bed[i])
		_maximum = maxf(_maximum, sim.bed[i])
	_phase.resize(_nx * _nz * 4)
	_phase.fill(0.0)
	_pack(sim, 0.0)
	_state_image = Image.create_from_data(_nx, _nz, false, Image.FORMAT_RGBAF, _state.to_byte_array())
	_phase_image = Image.create_from_data(_nx, _nz, false, Image.FORMAT_RGBAF, _phase.to_byte_array())
	_state_textures.clear()
	_phase_textures.clear()
	for slot in 2:
		_state_textures.append(ImageTexture.create_from_image(_state_image))
		_phase_textures.append(ImageTexture.create_from_image(_phase_image))
	_material.set_shader_parameter("grid_texel", Vector2(1.0 / _nx, 1.0 / _nz))
	_material.set_shader_parameter("cell_m", sim.cell_m)
	_bind()
	set_interpolation(1.0)
	_build_mesh(sim)


func publish(sim, dt: float, only_dirty: bool = false) -> void:
	_pack(sim, dt, only_dirty)
	_current = 1 - _current
	_state_image.set_data(_nx, _nz, false, Image.FORMAT_RGBAF, _state.to_byte_array())
	_phase_image.set_data(_nx, _nz, false, Image.FORMAT_RGBAF, _phase.to_byte_array())
	_state_textures[_current].update(_state_image)
	_phase_textures[_current].update(_phase_image)
	_bind()
	# A new physical tick starts at its PREVIOUS image. Keeping last frame's
	# alpha=1 briefly shows the future, then moves backwards on the next frame.
	set_interpolation(0.0)
	publications += 1


func set_interpolation(alpha: float) -> void:
	_alpha = clampf(alpha, 0.0, 1.0)
	for material in _materials:
		material.set_shader_parameter("interpolation_alpha", _alpha)


func add_material(material: ShaderMaterial, cell_m: float) -> void:
	_materials.append(material)
	for key in _geometry: material.set_shader_parameter(key, _geometry[key])
	material.set_shader_parameter("grid_texel", Vector2(1.0 / _nx, 1.0 / _nz))
	material.set_shader_parameter("cell_m", cell_m)
	material.set_shader_parameter("interpolation_alpha", _alpha)
	_bind()


func _bind() -> void:
	for material in _materials:
		material.set_shader_parameter("state_previous", _state_textures[1 - _current])
		material.set_shader_parameter("state_current", _state_textures[_current])
		material.set_shader_parameter("phase_previous", _phase_textures[1 - _current])
		material.set_shader_parameter("phase_current", _phase_textures[_current])


func _pack(sim, dt: float, only_dirty: bool = false) -> void:
	var dirty: PackedInt32Array = sim.take_visual_dirty()
	if not only_dirty or dt == 0.0:
		var cleared := PackedInt32Array()
		for i in dirty:
			if sim.volume_q[i] == 0: cleared.append(i)
		dirty = sim.wet_indices.duplicate()
		dirty.append_array(cleared)
	for i in dirty:
		if sim.volume_q[i] == 0:
			_state[i * 4] = 0.0; _state[i * 4 + 1] = 0.0; _state[i * 4 + 2] = 1.0
			_phase[i * 4] = 0.0; _phase[i * 4 + 1] = 0.0; _phase[i * 4 + 2] = 0.0
			phases[i] = Vector2.ZERO
			continue
		var depth: float = sim.depth[i]
		var temperature: float = sim.temperature[i]
		var crust := clampf(1.0 - exp(-sim.age[i] / 55.0), 0.0, 0.94)
		crust = maxf(crust, 1.0 - clampf((temperature - 950.0) / 150.0, 0.0, 1.0))
		phases[i] += sim.velocity[i] * dt
		var j := i * 4
		_state[j] = depth
		_state[j + 1] = clampf((temperature - 850.0) / 350.0, 0.0, 1.0)
		_state[j + 2] = crust
		_state[j + 3] = sim.bed[i]
		_phase[j] = phases[i].x
		_phase[j + 1] = phases[i].y
		_phase[j + 2] = sim.opacity[i]
		_maximum = maxf(_maximum, sim.bed[i] + depth)
	# Shader-displaced geometry needs explicit bounds, including both frames.
	var fresh := AABB(Vector3(0, _minimum - 0.1, 0),
		Vector3((_nx - 1) * sim.cell_m, _maximum - _minimum + 0.2, (_nz - 1) * sim.cell_m))
	if sim.geometry_mode == 1:
		var radius: float = sim.radial_edges_mm[-1] / 1000.0
		fresh = AABB(Vector3(-radius, _minimum - 0.1, -radius), Vector3(2 * radius, _maximum - _minimum + 0.2, 2 * radius))
	bounds = fresh if dt == 0.0 else bounds.merge(fresh)


func _build_mesh(sim) -> void:
	mesh_builds += 1
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var indices := PackedInt32Array()
	if sim.geometry_mode == 1:
		for row in _nz + 2:
			var z := clampi(row - 1, 0, _nz - 1)
			var radius: float = 0.0 if row == 0 else (sim.radial_edges_mm[-1] / 1000.0 if row == _nz + 1 else sim.radial_centres[z])
			for x in _nx + 1:
				var angle := (x + 0.5) * TAU / _nx
				var point := Vector2(cos(angle), sin(angle)) * radius
				vertices.append(Vector3(point.x, sim.bed[z * _nx + x % _nx], point.y))
				normals.append(Vector3.UP); uv.append(point)
				uv2.append(Vector2((x + 0.5) / _nx, (z + 0.5) / _nz))
		for row in _nz + 1:
			for x in _nx:
				var i := row * (_nx + 1) + x
				var below := i + _nx + 1
				indices.append_array(PackedInt32Array([i, below, i + 1, i + 1, below, below + 1]))
	else:
		for z in _nz:
			for x in _nx:
				vertices.append(Vector3(x * sim.cell_m, sim.bed[z * _nx + x], z * sim.cell_m))
				normals.append(Vector3.UP)
				uv.append(Vector2(x, z) * sim.cell_m)
				uv2.append(Vector2((x + 0.5) / _nx, (z + 0.5) / _nz))
		for z in _nz - 1:
			for x in _nx - 1:
				var i := z * _nx + x
				indices.append_array(PackedInt32Array([i, i + 1, i + _nx, i + 1, i + _nx + 1, i + _nx]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
