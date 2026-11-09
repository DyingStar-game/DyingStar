extends MultiMeshInstance3D
## Client-only cosmetic pool. Never changes a solver, tick, source or RNG.
## Fixed 96 billboard slots, 6s lifetime, 8 births/s, edge scan at 2 Hz.

const SHADER = preload("res://assets/_universe/environment/terrain/lava_edge_smoke.gdshader")
const CAPACITY := 96
var smoke_enabled := true
## The lava runtime scans the edges on its tick worker: advance() then only raises scan_wanted.
var deferred_scan := false
## A scan is due and waits for the runtime's next worker job.
var scan_wanted := false
var clock := 0.0
var active_count := 0
var edge_count := 0
var _expiry := PackedFloat64Array()
var _edges := PackedVector3Array()
var _heat := PackedFloat32Array()
var _material: ShaderMaterial
var _scan_clock := 0.0
var _birth_clock := 0.0
var _sequence := 0


func _init() -> void:
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	multimesh.mesh = quad
	multimesh.instance_count = CAPACITY
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	reset()


func reset() -> void:
	clock = 0.0
	_scan_clock = 0.0
	_birth_clock = 0.0
	_sequence = 0
	active_count = 0
	edge_count = 0
	scan_wanted = false
	_edges.clear()
	_heat.clear()
	_expiry.resize(CAPACITY)
	_expiry.fill(-1.0)
	for i in CAPACITY:
		multimesh.set_instance_custom_data(i, Color(0, 0, 0, 0))
	_material.set_shader_parameter("smoke_clock", 0.0)


func set_smoke_enabled(enabled: bool) -> void:
	smoke_enabled = enabled
	visible = enabled
	if not enabled:
		reset()


## [param sim] is null while a worker job owns the solver: the smoke then ages without scanning it.
func advance(delta: float, sim) -> void:
	if not smoke_enabled:
		return
	clock += delta
	_material.set_shader_parameter("smoke_clock", fmod(clock, 32.0))
	for i in CAPACITY:
		if _expiry[i] >= 0.0 and clock >= _expiry[i]:
			_expiry[i] = -1.0
			active_count -= 1
			multimesh.set_instance_custom_data(i, Color(0, 0, 0, 0))
	_scan_clock -= delta
	if _scan_clock <= 0.0:
		if deferred_scan and _scan_clock > -1.0 or sim == null:
			scan_wanted = true  # the next worker job scans (apply_edges); synchronous after 1 s without one
		else:
			_scan_clock = 0.5
			_scan_edges(sim)
	_birth_clock = minf(_birth_clock + delta, 0.5)
	while _birth_clock >= 0.125:
		_birth_clock -= 0.125
		_spawn()


func _scan_edges(sim) -> void:
	apply_edges(edges_of(sim))


## Main thread: the edges found by [method edges_of] (on a worker) become the smoke's birth places.
func apply_edges(found: Array) -> void:
	scan_wanted = false
	_scan_clock = 0.5
	_edges = found[0]
	_heat = found[1]
	edge_count = _edges.size()
	if not _edges.is_empty():
		var bounds := AABB(_edges[0], Vector3.ZERO)
		for point in _edges: bounds = bounds.expand(point)
		custom_aabb = bounds.grow(16.0)


## [edges, heat] of the hot lava fronts of [param sim]. Reads the solver only: a worker that owns it may
## call it (~3 ms over 3 000 wet cells, too much for the main thread twice a second).
static func edges_of(sim) -> Array:
	var edges := PackedVector3Array()
	var heat := PackedFloat32Array()
	var depths: PackedFloat64Array = sim.depth
	var temperatures: PackedFloat64Array = sim.temperature
	var positions: PackedVector2Array = sim.positions
	var neighbors: PackedInt32Array = sim._neighbors
	for i: int in sim.active_indices:
		if depths[i] < 0.015 or temperatures[i] < 900.0: continue
		for d in 4:
			var j := neighbors[i * 4 + d]
			if j < 0 or depths[j] >= 0.004: continue
			var point := positions[i].lerp(positions[j], 0.4)
			var y: float = maxf(sim.bed[i] + depths[i], sim.bed[j]) + 0.25
			edges.append(Vector3(point.x, y, point.y))
			heat.append(clampf((temperatures[i] - 850.0) / 350.0, 0.1, 1.0))
			break
	return [edges, heat]



func _spawn() -> void:
	if _edges.is_empty():
		return
	for slot in CAPACITY:
		if _expiry[slot] >= 0.0:
			continue
		var edge := (_sequence * 37) % _edges.size()
		var seed_value := float((_sequence * 47) % 251) / 251.0
		multimesh.set_instance_transform(slot, Transform3D(Basis.IDENTITY, _edges[edge]))
		multimesh.set_instance_custom_data(slot, Color(fmod(clock, 32.0), seed_value, _heat[edge], 0.0))
		_expiry[slot] = clock + 6.0
		active_count += 1
		_sequence += 1
		return
