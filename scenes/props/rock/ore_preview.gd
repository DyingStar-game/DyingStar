@tool
extends Node3D

# BENCH (local, do not ship): spawns the REAL mining rock to study the ore + cut faces.
# Mirrors rock_mining's logic: shared ore offset + shared richness for ALL pieces, so a
# cut only REVEALS the 3D field. Progressive cutting (like in-game perforation):
#   F6: left-click = cut the ONE fault nearest the click on the aimed piece (down to 4
#   pieces); right-drag = orbit; wheel = zoom; R = reset.

const ORE_SHADER := preload("res://assets/_universe/environment/terrain/rocks/rock_vein.gdshader")
const ROCK_MESH := preload("res://assets/_universe/environment/terrain/rocks/rock_mining_001.mesh")
const ROCK_TEX := preload("res://assets/textures/grounds/rock/Rock029_2K_Color.jpg")

# Purity 0..1 maps to the ore threshold: 100% pure = lots of ore (low threshold).
const ORE_T_RICH := 0.40  # threshold at 100% purity
const ORE_T_POOR := 0.72  # threshold at 0% purity

## Tiling of the rock's albedo texture (multiplier on local coordinates): higher = smaller, more repeated pattern.
@export var tex_scale: float = 1.0

## Mineral to preview (gold, cryptonite, ...). When set, it drives the ORE LOOK exactly like
## in-game (so the bench = the game); leave null to tune the look with the Ore params below.
@export var mineral: MineralDef = preload("res://assets/_universe/_shared/materials/minerals/gold/gold.tres")

@export_group("Ore — interior (cut faces) + shared")
## Ore colour on cut faces and exterior traces. Used only when mineral is null.
@export var ore_color: Color = Color(0.1, 0.8, 0.2)
## Frequency of the interior ore noise on cut faces: higher = smaller, more numerous veins.
@export var ore_scale: float = 6.0
## Ore noise threshold (0..1, lower = more ore). Currently unused: the interior threshold comes from the
## random shared purity (ORE_T_POOR..ORE_T_RICH).
@export_range(0.0, 1.0) var ore_threshold: float = 0.543
## Edge blend of the ore above its threshold (0..0.5): 0 = hard-edged veins, higher = softer edges.
## Also used when estimating the ore fraction.
@export_range(0.0, 0.5) var ore_softness: float = 0.156
## Ore metallic (0..1). Used only when mineral is null.
@export_range(0.0, 1.0) var ore_metallic: float = 1.0
## Ore roughness (0..1): lower = shinier. Used only when mineral is null.
@export_range(0.0, 1.0) var ore_roughness: float = 0.059
## Ore glow strength (emission multiplier on the ore colour). Used only when mineral is null.
@export var ore_emission: float = 9.3

@export_group("Ore — exterior traces (decoupled from richness)")
## The uncut surface shows only a FEW TINY traces (Kainan): high scale = small spots,
## high threshold = rare. Independent from the interior richness.
@export var ore_ext_scale: float = 14.0
## Threshold (0..1) of the exterior ore traces: higher = rarer traces on the uncut surface.
@export_range(0.0, 1.0) var ore_ext_threshold: float = 0.7

@export_group("Faults (neutral grooves)")
## Width of the fault grooves, in rock-local units (it varies along the crack). Higher = wider cracks.
@export var groove_width: float = 0.03
## Albedo multiplier at the crack (lower = darker; 0 = black crack).
@export_range(0.0, 1.0) var groove_darkness: float = 0.0
## Carve depth of the groove bump (set negative if it looks raised instead of dug).
@export var groove_strength: float = 0.1

@export_group("Bench camera")
## Bench camera distance (m) from the rock. The mouse wheel changes it at runtime (minimum 1 m).
@export var orbit_radius: float = 5.0

# Same predefined faults as the real rock (rock_mining.gd).
var _faults := [
	{"position": 0.5, "rotation_y": 0.0, "rotation_z": 8.0},
	{"position": 0.5, "rotation_y": 0.0, "rotation_z": 82.0},
]
var _rock_mat: ShaderMaterial = null  # uncut piece's exterior mat (for editor live-tuning)
var _mesh_center: Vector3 = Vector3.ZERO
var _cam: Camera3D = null
var _orbit_yaw: float = 0.0
var _orbit_pitch: float = 0.3
var _dragging: bool = false
# Each piece: { "node": CSGCombiner3D, "cuts": Array[{ "f": int, "ks": int }] }.
var _pieces: Array = []
var _hud: Label = null
var _pending_click: Vector2 = Vector2(-1.0, -1.0)  # a cut click to raycast in physics
var _rock_offset: Vector3 = Vector3.ZERO  # shared ore distribution offset (in-game: uuid)
var _shared_purity: float = 0.6  # shared richness for ALL pieces (in-game: from the seed)

func _ready() -> void:
	_build()
	_cam = get_node_or_null("Camera3D")
	if not Engine.is_editor_hint():
		var layer := CanvasLayer.new()
		_hud = Label.new()
		_hud.position = Vector2(20, 20)
		_hud.add_theme_font_size_override("font_size", 22)
		_hud.text = "Clic gauche : couper la faille visée"
		layer.add_child(_hud)
		add_child(layer)
		if _cam != null:
			_cam.make_current()
			_update_camera()

func _process(_delta: float) -> void:
	# Editor: keep a single uncut rock and live-apply the ore params for tuning.
	if Engine.is_editor_hint():
		if _pieces.is_empty():
			_build()
		else:
			_apply_uncut()

func _physics_process(_delta: float) -> void:
	# Raycasts must run here: the space state is null outside physics.
	if Engine.is_editor_hint():
		return
	if _pending_click.x >= 0.0:
		_handle_cut_click(_pending_click)
		_pending_click = Vector2(-1.0, -1.0)

func _build() -> void:
	for p in _pieces:
		if is_instance_valid(p.node):
			p.node.queue_free()
	_pieces.clear()
	_mesh_center = ROCK_MESH.get_aabb().get_center()
	_rock_offset = _rand_offset()
	_shared_purity = randf()
	# Start with one uncut piece (all faults shown as neutral grooves).
	_make_piece([])

## Push the ore params to a material (shared by every rock material).
func _apply_ore(mat: ShaderMaterial, scale: float, threshold: float, offset: Vector3) -> void:
	mat.set_shader_parameter("albedo_tex", ROCK_TEX)
	mat.set_shader_parameter("tex_scale", tex_scale)
	mat.set_shader_parameter("ore_scale", scale)
	mat.set_shader_parameter("ore_threshold", threshold)
	mat.set_shader_parameter("ore_softness", ore_softness)
	mat.set_shader_parameter("noise_offset", offset)
	mat.set_shader_parameter("groove_width", groove_width)
	mat.set_shader_parameter("groove_darkness", groove_darkness)
	mat.set_shader_parameter("groove_strength", groove_strength)
	# Ore LOOK: from the mineral (matches in-game) when set, else the bench's own params.
	if mineral != null:
		mat.set_shader_parameter("ore_use_texture", mineral.use_texture)
		mat.set_shader_parameter("ore_albedo_tex", mineral.albedo_tex)
		mat.set_shader_parameter("ore_normal_tex", mineral.normal_tex)
		mat.set_shader_parameter("ore_tex_scale", mineral.tex_scale)
		mat.set_shader_parameter("ore_normal_strength", mineral.normal_strength)
		mat.set_shader_parameter("ore_color", mineral.color)
		mat.set_shader_parameter("ore_metallic", mineral.metallic)
		mat.set_shader_parameter("ore_roughness", mineral.roughness)
		mat.set_shader_parameter("ore_emission", mineral.emission)
	else:
		mat.set_shader_parameter("ore_use_texture", false)
		mat.set_shader_parameter("ore_color", ore_color)
		mat.set_shader_parameter("ore_metallic", ore_metallic)
		mat.set_shader_parameter("ore_roughness", ore_roughness)
		mat.set_shader_parameter("ore_emission", ore_emission)

## Editor live-tuning: re-push params to the uncut rock's exterior material + grooves.
func _apply_uncut() -> void:
	if _rock_mat == null:
		return
	_apply_ore(_rock_mat, ore_ext_scale, ore_ext_threshold, _rock_offset)
	_set_grooves(_rock_mat, [])

## Show neutral grooves for the faults NOT in `cut_idxs` (the ones still cuttable).
func _set_grooves(mat: ShaderMaterial, cuts: Array) -> void:
	var cut_set := {}
	for c in cuts:
		cut_set[c.f] = true
	var normals: Array = []
	var offsets: Array = []
	for i in _faults.size():
		if cut_set.has(i):
			continue
		var n: Vector3 = _fault_normal(_faults[i])
		normals.append(n)
		offsets.append((0.5 - _faults[i].position) + n.dot(_mesh_center))
	mat.set_shader_parameter("plane_count", normals.size())
	mat.set_shader_parameter("plane_normals", normals)
	mat.set_shader_parameter("plane_offsets", offsets)

## Build a piece = base mesh minus a cut box per applied cut. Exterior = few tiny traces +
## grooves for the remaining faults; cut faces = shared richness. Returns its dict.
func _make_piece(cuts: Array) -> Dictionary:
	var ext_mat := ShaderMaterial.new()
	ext_mat.shader = ORE_SHADER
	_apply_ore(ext_mat, ore_ext_scale, ore_ext_threshold, _rock_offset)
	_set_grooves(ext_mat, cuts)
	var inner_mat := _new_ore_mat(ore_scale, lerpf(ORE_T_POOR, ORE_T_RICH, _shared_purity), _rock_offset)
	var node := CSGCombiner3D.new()
	node.use_collision = true
	var base := CSGMesh3D.new()
	base.mesh = ROCK_MESH
	base.material = ext_mat
	node.add_child(base)
	for c in cuts:
		node.add_child(_make_cut_box(_faults[c.f], c.ks, inner_mat))
	node.set_meta("is_rock_piece", true)
	add_child(node)
	var piece := {"node": node, "cuts": cuts}
	_pieces.append(piece)
	if cuts.is_empty():
		_rock_mat = ext_mat  # for editor live-tuning
	return piece

## Cut a piece along ONE fault: replace it with its two halves (keep_side 1 and 2), each
## inheriting the existing cuts + the new one, nudged apart along the fault normal.
func _split_piece(piece: Dictionary, fault_idx: int) -> void:
	var n: Vector3 = _fault_normal(_faults[fault_idx])
	var base_pos: Vector3 = piece.node.position
	for ks in [1, 2]:
		var new_cuts: Array = piece.cuts.duplicate(true)
		new_cuts.append({"f": fault_idx, "ks": ks})
		var np := _make_piece(new_cuts)
		np.node.position = base_pos + n * (0.5 if ks == 2 else -0.5)
	piece.node.queue_free()
	_pieces.erase(piece)

func _fault_normal(f: Dictionary) -> Vector3:
	return Basis.from_euler(Vector3(0.0, deg_to_rad(f.rotation_y), deg_to_rad(f.rotation_z))) * Vector3(1.0, 0.0, 0.0)

## A piece material: ore at the shared richness (threshold). No grooves (cut faces, not cracks).
func _new_ore_mat(scale: float, threshold: float, offset: Vector3) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ORE_SHADER
	_apply_ore(m, scale, threshold, offset)
	m.set_shader_parameter("plane_count", 0)
	return m

## Shared per-rock ore distribution offset (in-game it comes from the uuid/seed).
func _rand_offset() -> Vector3:
	return Vector3(randf() * 100.0, randf() * 100.0, randf() * 100.0)

## CSG box that removes one half of a fault (centered like the real rock). keep_side picks
## which half stays. Same ore material so the cut faces match the piece.
func _make_cut_box(f: Dictionary, keep_side: int, mat: ShaderMaterial) -> CSGBox3D:
	var box := CSGBox3D.new()
	box.size = Vector3(20.0, 20.0, 20.0)
	box.rotation = Vector3(0.0, deg_to_rad(f.rotation_y), deg_to_rad(f.rotation_z))
	box.translate_object_local(Vector3(10.5, 0.0, 0.0))
	box.translate_object_local(Vector3(-f.position, 0.0, 0.0))
	box.translate_object_local(Vector3(_fault_normal(f).dot(_mesh_center), 0.0, 0.0))
	if keep_side == 2:
		box.translate_object_local(Vector3(-20.0, 0.0, 0.0))
	box.operation = CSGShape3D.OPERATION_SUBTRACTION
	box.material = mat
	return box

func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_pending_click = event.position  # handled in _physics_process
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			orbit_radius = maxf(1.0, orbit_radius - 0.4)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			orbit_radius += 0.4
			_update_camera()
	elif event is InputEventMouseMotion and _dragging:
		_orbit_yaw -= event.relative.x * 0.01
		_orbit_pitch = clampf(_orbit_pitch - event.relative.y * 0.01, -1.4, 1.4)
		_update_camera()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_R:
		_build()
		if _hud != null:
			_hud.text = "Clic gauche : couper la faille visée"

func _update_camera() -> void:
	if _cam == null:
		return
	var dir := Vector3(
		cos(_orbit_pitch) * sin(_orbit_yaw),
		sin(_orbit_pitch),
		cos(_orbit_pitch) * cos(_orbit_yaw))
	_cam.position = dir * orbit_radius
	_cam.look_at(Vector3.ZERO, Vector3.UP)

## Raycast from the mouse to a piece and cut the fault nearest the hit point.
func _handle_cut_click(mouse_pos: Vector2) -> void:
	if _cam == null:
		return
	var from: Vector3 = _cam.project_ray_origin(mouse_pos)
	var to: Vector3 = from + _cam.project_ray_normal(mouse_pos) * 1000.0
	var params := PhysicsRayQueryParameters3D.create(from, to)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(params)
	if hit.is_empty():
		return
	var node: Node = hit.get("collider")
	while node != null and not node.has_meta("is_rock_piece"):
		node = node.get_parent()
	if node == null:
		return
	var piece = null
	for p in _pieces:
		if p.node == node:
			piece = p
			break
	if piece == null:
		return
	# Pick the still-cuttable fault whose plane is nearest the clicked point (piece-local).
	var hit_local: Vector3 = node.to_local(hit.get("position"))
	var cut_set := {}
	for c in piece.cuts:
		cut_set[c.f] = true
	var best := -1
	var best_d := INF
	for i in _faults.size():
		if cut_set.has(i):
			continue
		var n: Vector3 = _fault_normal(_faults[i])
		var off: float = (0.5 - _faults[i].position) + n.dot(_mesh_center)
		var d: float = absf(n.dot(hit_local) - off)
		if d < best_d:
			best_d = d
			best = i
	# Value (purity) of the clicked piece = ore fraction measured over its volume.
	var val := _measure_value(node)
	if best < 0:
		if _hud != null:
			_hud.text = "Valeur du morceau : %d%% (entièrement fracturé)" % int(round(val * 100.0))
		return
	_split_piece(piece, best)
	if _hud != null:
		_hud.text = "Valeur cliquée : %d%% — coupe (%d morceaux)" % [int(round(val * 100.0)), _pieces.size()]

## Per-piece value: fraction of the piece's volume that is ore, sampling the SAME 3D field
## the shader draws (so the value matches the ore you see). Mirrors rock_mining.measured_purity.
func _measure_value(node: Node) -> float:
	var box: AABB = node.get_aabb()  # CSGCombiner3D is a GeometryInstance3D
	var threshold := lerpf(ORE_T_POOR, ORE_T_RICH, _shared_purity)
	var n_side := 4
	var total := 0.0
	for ix in n_side:
		for iy in n_side:
			for iz in n_side:
				var p := box.position + Vector3(
					box.size.x * (float(ix) + 0.5) / n_side,
					box.size.y * (float(iy) + 0.5) / n_side,
					box.size.z * (float(iz) + 0.5) / n_side)
				var nz := _fbm3((p + _rock_offset) * ore_scale)
				total += smoothstep(threshold, threshold + ore_softness, nz)
	return total / float(n_side * n_side * n_side)

# --- GDScript replica of rock_ore_bench.gdshader's value-noise fbm (keep in sync). ---
func _sfract(x: float) -> float:
	return x - floor(x)

func _hash3(p: Vector3) -> float:
	var q := Vector3(_sfract(p.x * 0.3183099 + 0.1), _sfract(p.y * 0.3183099 + 0.1), _sfract(p.z * 0.3183099 + 0.1))
	q *= 17.0
	return _sfract(q.x * q.y * q.z * (q.x + q.y + q.z))

func _vnoise3(x: Vector3) -> float:
	var i := Vector3(floor(x.x), floor(x.y), floor(x.z))
	var f := Vector3(_sfract(x.x), _sfract(x.y), _sfract(x.z))
	f = f * f * (Vector3(3.0, 3.0, 3.0) - f * 2.0)
	var x00 := lerpf(_hash3(i), _hash3(i + Vector3(1, 0, 0)), f.x)
	var x10 := lerpf(_hash3(i + Vector3(0, 1, 0)), _hash3(i + Vector3(1, 1, 0)), f.x)
	var x01 := lerpf(_hash3(i + Vector3(0, 0, 1)), _hash3(i + Vector3(1, 0, 1)), f.x)
	var x11 := lerpf(_hash3(i + Vector3(0, 1, 1)), _hash3(i + Vector3(1, 1, 1)), f.x)
	return lerpf(lerpf(x00, x10, f.y), lerpf(x01, x11, f.y), f.z)

func _fbm3(p: Vector3) -> float:
	var v := 0.0
	var a := 0.5
	var pp := p
	for _i in 4:
		v += a * _vnoise3(pp)
		pp *= 2.0
		a *= 0.5
	return v
