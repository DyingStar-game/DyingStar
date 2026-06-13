extends RigidBody3D

## Networked, carriable, fracturable mining rock. All networking (uuid, replication, reparent, delete,
## bed-ride) lives in the PropSync child node (type_name "miningrock", enable_carry = true). Custom state
## (blocs/cut geometry, ore, mineral) is applied via apply_prop_data(); server-side updates go out via
## the PropSync component. The body keeps the carry contract (interact / set_carried / uuid / carried)
## and the custom server_parent_change / send_properties_to_client that other systems call on it.

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

# Speed (m/s) the two halves get pushed apart along the fault normal when cut, so they
# don't stay stacked (especially on a horizontal cut).
const SEPARATION_SPEED := 1.5

# Speed (m/s) both pieces get pushed along the perforation direction (away from the bit
# / the player), so the rock recoils where the drill hits.
const PERFORATION_PUSH_SPEED := 2.5

# How close (rock-local units) two fault distances must be to count as "the same
# crossing": within this margin of the nearest fault, the LOWEST-numbered one is cut.
const INTERSECTION_MARGIN := 0.06

# Max distance (rock-local) from the aim point to a fault plane for the hit to count
# as "on a fault". Aiming farther than this = not on a vein -> no cut.
const FAULT_HIT_THRESHOLD := 0.05

# Legacy ore look — FALLBACK only, used when no MineralDef is assigned (see `mineral`). The
# real look now comes from MineralDef (.tres). Purity thresholds below drive ore_threshold:
# ORE_T_RICH = full of ore, ORE_T_POOR = almost none.
const ORE_COLOR := Color(0.1, 0.8, 0.2)
const ORE_SCALE := 6.0
const ORE_SOFTNESS := 0.156
const ORE_METALLIC := 1.0
const ORE_ROUGHNESS := 0.059
const ORE_EMISSION := 9.3
const ORE_T_RICH := 0.40
const ORE_T_POOR := 0.72
# Exterior (uncut surface): a FEW TINY traces only, DECOUPLED from the real richness, so
# the player must fracture once to see the actual ore inside (Kainan/DDURIEUX).
const ORE_T_EXTERIOR := 0.7  # high threshold -> very few spots
const ORE_SCALE_EXTERIOR := 14.0  # high scale -> tiny spots
# Fraction of a piece's bounding box that is actually solid (rough volume estimate).
const VOLUME_FILL := 0.5
# Registry id -> MineralDef, so a replicated mineral_id (string) resolves to its resource on
# every client/server. Keep in sync with assets/_universe/_shared/materials/minerals/.
const GOLD_MINERAL := preload("res://assets/_universe/_shared/materials/minerals/gold/gold.tres")
const MINERALS := {
	"gold": GOLD_MINERAL,
	"iron": preload("res://assets/_universe/_shared/materials/minerals/iron/iron.tres"),
	"cryptonite": preload("res://assets/_universe/_shared/materials/minerals/cryptonite/cryptonite.tres"),
}

## Which mineral this rock shows (gold, cryptonite, ...). Default = gold for now; per-rock
## attribution + replication come later. The ore FIELD (amount/dispersion) stays below.
@export var mineral: MineralDef = GOLD_MINERAL

@export_group("Fault look")
## Neutral fault grooves — they deliberately do NOT reveal the mineral. Width of the crack,
## darkening at its bottom (0 = black) and carved depth (negative = raised instead of dug).
@export var groove_width: float = 0.03
@export_range(0.0, 1.0) var groove_darkness: float = 0.0
@export var groove_strength: float = 0.1

var type_name = "miningrock"  # kept for internal blocs/side2 payloads; PropSync carries the networked copy

var combiner: CSGCombiner3D

# uuid / carried are read by mining_tool / player / vehicle on the body; forward to the PropSync child.
var uuid: String:
	get:
		var s := PropSync.of(self)
		return s.uuid if s != null else ""
	set(value):
		var s := PropSync.of(self)
		if s != null:
			s.uuid = value

var carried: bool:
	get:
		var s := PropSync.of(self)
		return s.carried if s != null else false
	set(value):
		var s := PropSync.of(self)
		if s != null:
			s.carried = value

# The parent we were created under (a valid GORC id, or "" for a root object).
# Reused for the broken-off half (side2) so Horizon can resolve its parent too:
# a non-empty parent_id that Horizon doesn't know is queued forever (never spawned).
var created_parent_id: String = ""

# Ore distribution seed (the original rock's id), inherited by broken-off pieces so their
# exterior stays continuous after a cut. Empty on the original -> it uses its own uuid.
var ore_seed: String = ""

# Predefined faults (fixed, not random) — shown as red veins; perforating a vein
# cuts the rock along it. keep_side = which half we keep when cut (the other half
# becomes a new rock). number = fault priority: when the aim point is on the crossing
# of several faults, the LOWEST number is cut.
var blocs = [
	{ "fractured": false, "number": 1, "position": 0.5, "rotation_y": 0.0, "rotation_z": 8.0, "keep_side": 1, "side2_uuid": "" },
	{ "fractured": false, "number": 2, "position": 0.5, "rotation_y": 0.0, "rotation_z": 82.0, "keep_side": 1, "side2_uuid": "" },
]

# Cut geometry: the mesh is rebuilt as "base mesh minus EVERY fractured fault", so a
# rock can be cut along several faults (a half can be split again -> down to 4 pieces).
var _base_mesh: Mesh = null
var _mesh_instance: MeshInstance3D = null
# Geometric center of the base mesh (its origin is not necessarily its middle), used
# so a fault at position 0.5 sits in the true middle along its normal.
var _mesh_center: Vector3 = Vector3.ZERO
# Half-size of the CSG subtraction box used to cut a fault, in rock-local units. Must reach
# past the rock surface from the center plane, so it scales with the rock (floored at 10 to
# keep the small variant's proven behavior). Computed once from the base mesh AABB.
var _cut_box_half: float = 10.0
# Uniform scale baked into the mesh (1 for small, >1 for medium/large). The fault-hit
# tolerances (FAULT_HIT_THRESHOLD / INTERSECTION_MARGIN) are in rock-local units, so they
# must be multiplied by this to stay proportional — otherwise a big rock is uncuttable.
var _fault_scale: float = 1.0
# Velocity to apply once when this piece spawns, to push it off the half it split from.
var _spawn_kick: Vector3 = Vector3.ZERO
# Cached per-piece ore fraction (sampled over the piece's volume). -1 = not computed yet;
# invalidated whenever the mesh is rebuilt (a cut).
var _purity := -1.0
# Mass (kg) of a WHOLE uncut rock — the GameDesigner value set on the RigidBody in the scene,
# captured at _ready. A cut piece weighs this scaled by its volume ratio (see _refresh_mass).
var _full_rock_mass: float = 0.0
@onready var rock_shape = $CollisionShape3D

func _ready() -> void:
	add_to_group("miningrock")  # for proximity detection (aim mode)
	add_to_group("carriable")  # so the carry pickup can resolve it by uuid (#124)
	_full_rock_mass = mass  # GameDesigner value from the scene = the whole-rock mass (before scaling)
	# Find the rock's CSGMesh3D child by TYPE, not by index: the scene also holds a PropSync
	# networking node (and possibly others), so get_child(0) is no longer guaranteed to be the mesh.
	var item_rock_mesh: CSGMesh3D = null
	for _child in get_children():
		if _child is CSGMesh3D:
			item_rock_mesh = _child
			break
	# Bake any uniform scale set on the mesh node into a scale-1 mesh, so every cut /
	# collision / ore computation below works in true-size local space. The small variant
	# is scale 1 (no-op); medium/large scale their mesh node (x4 / x10) for their size.
	if item_rock_mesh != null and not item_rock_mesh.scale.is_equal_approx(Vector3.ONE):
		var s: Vector3 = item_rock_mesh.scale
		_fault_scale = maxf(s.x, maxf(s.y, s.z))
		item_rock_mesh.mesh = _scaled_mesh(item_rock_mesh.mesh, s)
		item_rock_mesh.scale = Vector3.ONE
	_base_mesh = item_rock_mesh.mesh   # keep a ref to rebuild cuts later
	if _base_mesh != null:
		_mesh_center = _base_mesh.get_aabb().get_center()   # true middle of the rock
		# Box big enough to cover the rock from its center plane (diagonal), floored at the
		# small variant's original 10 so its cuts are bit-for-bit unchanged.
		_cut_box_half = maxf(10.0, _base_mesh.get_aabb().size.length())
	combiner = CSGCombiner3D.new()
	add_child(combiner)

	await get_tree().process_frame

	rock_shape.shape = item_rock_mesh.mesh.create_convex_shape(true)
	_refresh_mass()  # whole rock keeps the GD mass (volume ratio 1); cuts scale it down

	item_rock_mesh.reparent(combiner)

	if OS.has_feature("dedicated_server"):
		_server_ready()
	else:
		_client_ready()

## Return a copy of `src` with every vertex multiplied by `s` (uniform scale), so a
## mesh authored small can be baked to its true size at scale 1. Normals/UVs are kept as
## is (a uniform positive scale preserves normal direction). Used for medium/large variants.
func _scaled_mesh(src: Mesh, s: Vector3) -> ArrayMesh:
	var out := ArrayMesh.new()
	for surf in src.get_surface_count():
		var arrays: Array = src.surface_get_arrays(surf)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in verts.size():
			verts[i] *= s
		arrays[Mesh.ARRAY_VERTEX] = verts
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat: Material = src.surface_get_material(surf)
		if mat != null:
			out.surface_set_material(surf, mat)
	return out

## Rebuild the cut geometry from the current fault state (server + client). No cut
## yet -> keep the initial full-rock combiner and just (re)show the veins.
func _refresh_cuts() -> void:
	for bloc in blocs:
		if bloc.get("fractured", false):
			_rebuild()
			return
	if not OS.has_feature("dedicated_server"):
		_show_faults()

## Build the CSG box that subtracts one fault's half from the rock (rock-local).
func _make_cut_box(bloc: Dictionary) -> CSGBox3D:
	var box := CSGBox3D.new()
	box.size = Vector3(2.0 * _cut_box_half, 2.0 * _cut_box_half, 2.0 * _cut_box_half)
	# rotate before translating so the cut plane matches on both halves
	box.rotation = Vector3(0.0, deg_to_rad(bloc.rotation_y), deg_to_rad(bloc.rotation_z))
	box.translate_object_local(Vector3(_cut_box_half + 0.5, 0, 0))  # box on the far right of the rock
	box.translate_object_local(Vector3(-bloc.position, 0.0, 0.0))
	# Shift the cut plane onto the mesh center (along the fault normal) so position 0.5
	# is the true middle even when the mesh origin is off-center.
	var n: Vector3 = Basis.from_euler(Vector3(0.0, deg_to_rad(bloc.rotation_y), deg_to_rad(bloc.rotation_z))) * Vector3(1.0, 0.0, 0.0)
	box.translate_object_local(Vector3(n.dot(_mesh_center), 0.0, 0.0))
	if int(bloc.keep_side) == 2:
		box.translate_object_local(Vector3(-2.0 * _cut_box_half, 0, 0))   # cut the other half instead
	box.operation = CSGShape3D.OPERATION_SUBTRACTION
	return box

## Rebuild the rock mesh = base mesh minus EVERY fractured fault. Always rebuilt from
## scratch, so it is idempotent (replaying the same fault set changes nothing) and
## supports several cuts on the same rock: a half can be split again -> down to 4 pieces.
func _rebuild() -> void:
	if _base_mesh == null:
		return
	# The mesh (and thus the ore region inside it) changed: drop the cached purity.
	_purity = -1.0
	# Bake "base - all fractured boxes" with a throwaway combiner (kept transient so we
	# don't leave a live CSG node around for every rock).
	var temp := CSGCombiner3D.new()
	add_child(temp)
	var base := CSGMesh3D.new()
	base.mesh = _base_mesh
	temp.add_child(base)
	for bloc in blocs:
		if bloc.get("fractured", false):
			temp.add_child(_make_cut_box(bloc))
	await get_tree().process_frame
	var meshes = temp.get_meshes()
	var mesh: Mesh = meshes[1] if meshes.size() > 1 else null
	temp.queue_free()
	if mesh == null or mesh.get_surface_count() == 0:
		return
	mesh = _smooth_exterior(mesh)  # keep the exterior smooth (not faceted) after a cut
	# The first cut replaces the initial full-rock combiner with the baked mesh.
	if combiner != null and is_instance_valid(combiner):
		combiner.queue_free()
		combiner = null
	if _mesh_instance == null or not is_instance_valid(_mesh_instance):
		_mesh_instance = MeshInstance3D.new()
		add_child(_mesh_instance)
	_mesh_instance.mesh = mesh
	# Surface 0 = exterior (few tiny traces + fault grooves); surface 1 = cut faces (the
	# real ore richness). Forces a first fracture to reveal the actual ore (Kainan).
	_mesh_instance.set_surface_override_material(0, _make_exterior_material())
	_mesh_instance.set_surface_override_material(1, _make_inner_material())
	rock_shape.shape = mesh.create_convex_shape(true)
	_refresh_mass()  # a smaller piece weighs less (scaled by its volume vs the whole rock)
	# No manual recenter: each piece keeps the rock's transform and occupies its own
	# half of the original volume (Godot derives the rigid body's center of mass from
	# the offset shape). This keeps both halves in place instead of teleporting them.
	sleeping = false
	# Server only: kick this piece off the half it split from (set once on spawn).
	if GameOrchestrator.is_server() and _spawn_kick != Vector3.ZERO:
		linear_velocity += _spawn_kick
		_spawn_kick = Vector3.ZERO

## A CSG boolean re-triangulates and flattens the exterior normals, so a cut rock looks
## faceted vs the smooth uncut one. Recompute SMOOTH normals on the exterior (surface 0)
## and keep the cut faces (surface 1) untouched (they stay flat).
func _smooth_exterior(mesh: Mesh) -> Mesh:
	if not (mesh is ArrayMesh) or mesh.get_surface_count() == 0:
		return mesh
	var st := SurfaceTool.new()
	st.create_from(mesh, 0)
	st.index()              # merge coincident verts so shared normals can be averaged
	st.generate_normals()   # smooth normals -> the exterior is not faceted
	var out: ArrayMesh = st.commit()
	if mesh.get_surface_count() > 1:
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.surface_get_arrays(1))
	return out

## Server: replicate the full fault state to Horizon & clients after a cut.
func _replicate_blocs() -> void:
	var message1 = {
		"namespace": "props",
		"event": "position",
		"amessagenb": 1,
		"data": [
			{
				"type": "miningrock",
				"uuid": uuid,
				"blocs": _blocs_payload(),
			}
		]
	}
	ServerNetwork.send_message(message1, "prop_update")

## Serializable copy of the faults (no CSG node refs) for network messages.
func _blocs_payload() -> Array:
	var out := []
	for bloc in blocs:
		out.append({
			"fractured": bloc.get("fractured", false),
			"number": bloc.get("number", 0),
			"position": bloc.position,
			"rotation_y": bloc.rotation_y,
			"rotation_z": bloc.rotation_z,
			"keep_side": bloc.get("keep_side", 1),
			"side2_uuid": bloc.get("side2_uuid", ""),
		})
	return out

#####################################################################
# Client part
######################################################################

func _client_ready() -> void:
	_show_faults()
	# Created already under a vehicle (piece loaded before we arrived): ride it (KINEMATIC).
	PropNet.apply_ride_freeze_mode(self)

## Show each not-yet-fractured fault as a red vein (a thin slice through the rock)
## at its cut plane, so faults are visible before perforating.
func _show_faults() -> void:
	if combiner == null or not is_instance_valid(combiner):
		return   # already cut: the veins live on the rebuilt mesh instead
	var mesh_node = combiner.get_child(0) if combiner.get_child_count() > 0 else null
	if mesh_node is CSGMesh3D:
		(mesh_node as CSGMesh3D).material = _make_exterior_material()

## Rock material that draws red veins where the surface is near a not-yet-fractured
## fault plane (intersection only -> crack lines, nothing sticking out).
## Per-piece ore richness (0..1) = ore quantity = value. Deterministic from the uuid, so
## every client shows the same amount without replicating anything. A different uuid (the
## original and each broken-off piece) -> different richness -> the player compares.
func ore_richness() -> float:
	# Derive from the inherited ore seed (the original rock), NOT this piece's uuid, so the
	# 3D ore field (its threshold) is identical for every piece of the same rock. Cutting
	# then only REVEALS the ore; re-cutting a piece no longer changes the ore on its faces.
	var s: String = ore_seed if ore_seed != "" else uuid
	if s == "":
		return 0.5
	return float(absi(s.hash()) % 1000) / 1000.0

## Approximate outer radius of the rock (world units, mesh baked to true size at node
## scale 1). Tools measure distance to the SURFACE (center - radius) instead of the center,
## which is mandatory for the big variants whose center sits several metres inside the rock.
func aim_radius() -> float:
	if _base_mesh == null:
		return 0.0
	var ab: AABB = _base_mesh.get_aabb()
	return maxf(ab.size.x, maxf(ab.size.y, ab.size.z)) * 0.5

## Approximate volume of this piece (AABB of its mesh x a fill factor). Used by the mining
## depot to refine in volume (kg is meaningless in space — gravity varies).
func get_volume() -> float:
	var box: AABB
	if _mesh_instance != null and is_instance_valid(_mesh_instance) and _mesh_instance.mesh != null:
		box = _mesh_instance.mesh.get_aabb()
	elif _base_mesh != null:
		box = _base_mesh.get_aabb()
	else:
		return 1.0
	return box.size.x * box.size.y * box.size.z * VOLUME_FILL

## Volume of a WHOLE uncut rock (the base mesh every piece keeps a ref to). Used as the reference
## so a cut piece's mass scales by how much of the original rock it represents.
func _full_volume() -> float:
	if _base_mesh == null:
		return 0.0
	var box := _base_mesh.get_aabb()
	return box.size.x * box.size.y * box.size.z * VOLUME_FILL

## Set the rigid body mass from the piece's volume: the GameDesigner whole-rock mass for an uncut
## rock, scaled down by the volume ratio for a cut piece. This is what the truck bed counts as cargo.
func _refresh_mass() -> void:
	var full := _full_volume()
	if full > 0.0 and _full_rock_mass > 0.0:
		mass = maxf(1.0, _full_rock_mass * (get_volume() / full))

## Volume of ORE inside this piece = its volume x its MEASURED ore fraction (purity).
func get_ore_volume() -> float:
	return get_volume() * measured_purity()

## Per-piece ore fraction (0..1), measured by sampling the SAME 3D ore field the shader
## draws over this piece's volume. Because the field is shared by the whole rock (offset +
## threshold from the seed), bigger/ore-dense regions read richer -> purity varies per
## piece AND stays correlated with the ore you actually see on it. Cached (see _rebuild).
func measured_purity() -> float:
	if _purity >= 0.0:
		return _purity
	var box: AABB
	if _mesh_instance != null and is_instance_valid(_mesh_instance) and _mesh_instance.mesh != null:
		box = _mesh_instance.mesh.get_aabb()
	elif _base_mesh != null:
		box = _base_mesh.get_aabb()
	else:
		return ore_richness()  # not built yet: fall back to the rock's overall richness
	var threshold := lerpf(ORE_T_POOR, ORE_T_RICH, ore_richness())
	var offset := _ore_offset()
	var n_side := 4
	var total := 0.0
	for ix in n_side:
		for iy in n_side:
			for iz in n_side:
				var p := box.position + Vector3(
					box.size.x * (float(ix) + 0.5) / n_side,
					box.size.y * (float(iy) + 0.5) / n_side,
					box.size.z * (float(iz) + 0.5) / n_side)
				var nz := _fbm3((p + offset) * ORE_SCALE)
				total += smoothstep(threshold, threshold + ORE_SOFTNESS, nz)
	_purity = total / float(n_side * n_side * n_side)
	return _purity

# --- GDScript replica of rock_vein.gdshader's value-noise fbm (so the measured purity
#     matches the ore the shader actually renders). Keep in sync with the shader. ---
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

## Per-rock noise offset (deterministic from uuid) so each rock/piece shows a DIFFERENT
## ore distribution, identical on every client.
func _ore_offset() -> Vector3:
	var s: String = ore_seed if ore_seed != "" else uuid   # pieces inherit the original seed
	return Vector3(
		float(absi((s + "x").hash()) % 100000) / 1000.0,
		float(absi((s + "y").hash()) % 100000) / 1000.0,
		float(absi((s + "z").hash()) % 100000) / 1000.0)

## Build a rock material. ore_threshold/ore_scale set the ore amount/size; with_grooves
## adds the neutral fault grooves (only the exterior surface shows them).
func _make_rock_material(ore_threshold_v: float, ore_scale_v: float, with_grooves: bool) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://assets/_universe/environment/terrain/rocks/rock_vein.gdshader")
	mat.set_shader_parameter("albedo_tex", preload("res://assets/textures/grounds/rock/Rock029_2K_Color.jpg"))
	mat.set_shader_parameter("tex_scale", 1.0)
	# Ore LOOK (texture / colour / metalness) comes from the mineral; the ore FIELD
	# (amount, distribution) stays per-rock so fracture & purity behaviour is unchanged.
	_apply_mineral(mat)
	mat.set_shader_parameter("ore_scale", ore_scale_v)
	mat.set_shader_parameter("ore_threshold", ore_threshold_v)
	mat.set_shader_parameter("ore_softness", ORE_SOFTNESS)
	mat.set_shader_parameter("noise_offset", _ore_offset())  # per-rock ore distribution
	mat.set_shader_parameter("groove_width", groove_width)
	mat.set_shader_parameter("groove_darkness", groove_darkness)
	mat.set_shader_parameter("groove_strength", groove_strength)
	var normals: Array = []
	var offsets: Array = []
	if with_grooves:
		for bloc in blocs:
			if bloc.get("fractured", false):
				continue
			var r := Basis.from_euler(Vector3(0.0, deg_to_rad(bloc.rotation_y), deg_to_rad(bloc.rotation_z)))
			var n: Vector3 = r * Vector3(1.0, 0.0, 0.0)
			normals.append(n)                                            # fault plane normal (rock-local)
			offsets.append((0.5 - bloc.position) + n.dot(_mesh_center))  # plane offset, centered
	mat.set_shader_parameter("plane_count", normals.size())
	mat.set_shader_parameter("plane_normals", normals)
	mat.set_shader_parameter("plane_offsets", offsets)
	return mat

## Resolve a replicated mineral_id to its MineralDef and (re)apply the look. Safe to call
## before _ready (the look is then built with it); after _ready on a client, it rebuilds the
## displayed material so the rock switches mineral live.
func _set_mineral(id: String) -> void:
	if not MINERALS.has(id):
		return
	var m: MineralDef = MINERALS[id]
	if m == mineral:
		return
	mineral = m
	if not OS.has_feature("dedicated_server"):
		_reskin_current_mineral()

## Re-apply the mineral look to whatever geometry exists (the uncut combiner mesh, or the cut
## MeshInstance's two surfaces) WITHOUT rebuilding geometry. Rebuilding here would race the
## blocs-driven _rebuild() on the same frame and duplicate the mesh. No-op before the mesh
## exists — _client_ready then builds the look with the mineral already set.
func _reskin_current_mineral() -> void:
	if combiner != null and is_instance_valid(combiner) and combiner.get_child_count() > 0:
		var mesh_node = combiner.get_child(0)
		if mesh_node is CSGMesh3D:
			(mesh_node as CSGMesh3D).material = _make_exterior_material()
	if _mesh_instance != null and is_instance_valid(_mesh_instance):
		_mesh_instance.set_surface_override_material(0, _make_exterior_material())
		_mesh_instance.set_surface_override_material(1, _make_inner_material())

## Push the mineral's LOOK onto the shader (texture or flat colour + metalness). Falls back to
## the legacy hardcoded preset when no mineral is assigned, so a rock still renders.
func _apply_mineral(mat: ShaderMaterial) -> void:
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
		mat.set_shader_parameter("ore_color", ORE_COLOR)
		mat.set_shader_parameter("ore_metallic", ORE_METALLIC)
		mat.set_shader_parameter("ore_roughness", ORE_ROUGHNESS)
		mat.set_shader_parameter("ore_emission", ORE_EMISSION)

## Exterior (uncut surface): a few tiny ore traces, DECOUPLED from the real richness, plus
## the fault grooves. The player must fracture to reveal the actual ore inside (Kainan).
func _make_exterior_material() -> ShaderMaterial:
	return _make_rock_material(ORE_T_EXTERIOR, ORE_SCALE_EXTERIOR, true)

## Inner faces (revealed by a cut): the REAL ore amount = this piece's richness.
func _make_inner_material() -> ShaderMaterial:
	return _make_rock_material(lerpf(ORE_T_POOR, ORE_T_RICH, ore_richness()), ORE_SCALE, false)

# PropSync applies the replicated transform and the reparent/carry-collision handling; this then
# applies the rock's own (non-transform) fields. Replaces the old client_channel_data_update override.
func apply_prop_data(data: Dictionary) -> void:
	if data.has("parent_id"):
		created_parent_id = str(data["parent_id"])
	if data.has("ore_seed"):
		ore_seed = str(data["ore_seed"])
	if data.has("mineral_id"):
		_set_mineral(str(data["mineral_id"]))
	if data.has("kick"):
		_spawn_kick = Vector3(data["kick"]["x"], data["kick"]["y"], data["kick"]["z"])
	# Always re-derive the cut geometry from the replicated blocs (idempotent): a "skip if
	# unchanged" guard desyncs the mesh from blocs when a rebuild is interrupted mid-flap
	# (GORC churn), leaving the rock visually whole forever.
	if data.has("blocs"):
		blocs = data["blocs"]
		# _rebuild() needs `_base_mesh`, set in _ready(). When this rock is spawned
		# from the network, client_channel_data_update() is called *before* the node
		# enters the tree (see server/client.gd ~l.622), so _ready() hasn't run yet.
		# Wait until the node is ready before processing the blocs.
		if not is_node_ready():
			await ready
			await get_tree().process_frame  # let _ready() finish setting up the mesh
		_refresh_cuts()

#####################################################################
# Carry / drop (issue #124) — carriable contract, same as CarriableBox
#####################################################################

## A piece is "ore" (carriable) only once it has no fault left: every fault fractured
## means it can't be split anymore.
func is_fully_fractured() -> bool:
	for bloc in blocs:
		if not bloc.get("fractured", false):
			return false
	return true

## Carriable contract (same shape as CarriableBox.interact): the player asks the object
## whether it can be picked up — it stays generic, the rule lives here. Only a
## fault-less, not-already-carried piece can be carried.
func interact(_interactor: Node = null) -> bool:
	return is_fully_fractured() and not carried

## Mark/unmark as carried so another player can't grab it while it is in hands.
## A carried ore KEEPS its collision (solid to the world and other players); the carrier adds a
## collision exception with it instead, so it isn't blocked by the piece it carries (issue #124).
func set_carried(value: bool) -> void:
	carried = value

## Geometry center relative to the body origin: a cut piece keeps the original rock's
## pivot, so its mesh sits off to one side. The carrier uses this to hold the ore by its
## middle. Deterministic from `blocs`, so server and clients agree without extra sync.
func get_center_offset() -> Vector3:
	if _mesh_instance != null and is_instance_valid(_mesh_instance):
		return _mesh_instance.get_aabb().get_center()
	return _mesh_center

## Reparent on the server (carry into hands / drop back to the world) via the PropSync component, which
## sets its reparent guard so the momentary tree-exit isn't seen as a despawn.
func server_parent_change(parent: Node) -> void:
	var s := PropSync.of(self)
	if s != null:
		s.server_parent_change(parent)

## Tell clients to reparent this piece (into the carrier's hands, or back to the world)
## and where it sits. Same channel/shape Box50cm uses for carrying — routed through PropSync.
func send_properties_to_client(parent_uuid: String) -> void:
	var s := PropSync.of(self)
	if s == null:
		return
	s.server_prop_update({
		"position": snapped(position, Vector3(0.001, 0.001, 0.001)),
		"rotation": snapped(rotation, Vector3(0.0001, 0.0001, 0.0001)),
		"parent_id": parent_uuid,
		"weight": mass,
	})

#####################################################################
# Server part
#####################################################################

func _server_ready() -> void:
	# send blocs to Horizon (through the PropSync component)
	var s := PropSync.of(self)
	if s != null:
		s.server_prop_update({"blocs": _blocs_payload()})
	_refresh_cuts()

## True if a rock-local point lies on a not-yet-fractured fault (close to its plane).
## Used by the client to decide whether perforating there should do anything.
func is_on_fault(hit_local: Vector3) -> bool:
	for bloc in blocs:
		if bloc.get("fractured", false):
			continue
		var r := Basis.from_euler(Vector3(0.0, deg_to_rad(bloc.rotation_y), deg_to_rad(bloc.rotation_z)))
		var n: Vector3 = r * Vector3(1.0, 0.0, 0.0)
		var d: float = absf(n.dot(hit_local) - ((0.5 - bloc.position) + n.dot(_mesh_center)))
		if d <= FAULT_HIT_THRESHOLD * _fault_scale:
			return true
	return false

## Server: perforate the fault nearest to `hit_local` (a rock-local point) and cut
## along it. `push_dir_local` = perforation direction (rock-local) used to recoil the
## pieces away from the bit. The remaining faults stay cuttable (several cuts possible).
func server_perforate(hit_local: Vector3, push_dir_local: Vector3 = Vector3.ZERO) -> void:
	if not OS.has_feature("dedicated_server"):
		return
	# Distance from the aim point to each un-fractured fault plane (centered on the mesh,
	# must match _make_cut_box / _make_vein_material else we'd pick the wrong fault).
	var dists: Dictionary = {}
	var best_i := -1
	var best_d := INF
	for i in blocs.size():
		var bloc = blocs[i]
		if bloc.get("fractured", false):
			continue   # already cut along this fault
		var r := Basis.from_euler(Vector3(0.0, deg_to_rad(bloc.rotation_y), deg_to_rad(bloc.rotation_z)))
		var n: Vector3 = r * Vector3(1.0, 0.0, 0.0)
		var d: float = absf(n.dot(hit_local) - ((0.5 - bloc.position) + n.dot(_mesh_center)))
		dists[i] = d
		if d < best_d:
			best_d = d
			best_i = i
	if best_i < 0:
		return
	if best_d > FAULT_HIT_THRESHOLD * _fault_scale:
		return   # the aim point isn't on any fault -> nothing happens
	# Intersection priority: when the aim point sits on the crossing of several faults
	# (their distances are nearly tied), cut the one with the LOWEST number.
	var best_number: int = int(blocs[best_i].get("number", 9999))
	for i in dists:
		if dists[i] <= best_d + INTERSECTION_MARGIN * _fault_scale:
			var num: int = int(blocs[i].get("number", 9999))
			if num < best_number:
				best_number = num
				best_i = i
	# Cut our half along the fault, then spawn the complementary half (side2). Push the
	# two apart along the fault normal so they don't stay stacked.
	blocs[best_i].fractured = true
	var cut: Dictionary = blocs[best_i]
	var n_local: Vector3 = Basis.from_euler(Vector3(0.0, deg_to_rad(cut.rotation_y), deg_to_rad(cut.rotation_z))) * Vector3(1.0, 0.0, 0.0)
	var n_world: Vector3 = (global_transform.basis * n_local).normalized()
	# Recoil both pieces away from the bit (along the perforation direction).
	var push_world: Vector3 = Vector3.ZERO
	if push_dir_local.length() > 0.0001:
		push_world = (global_transform.basis * push_dir_local).normalized() * PERFORATION_PUSH_SPEED
	await _rebuild()
	# Our half: pushed along the perforation dir + away from the cut plane (-normal).
	linear_velocity += push_world - n_world * SEPARATION_SPEED
	_server_create_side2_rock(best_i, push_world + n_world * SEPARATION_SPEED)
	_replicate_blocs()

# The replicated scene path (registry key, no res:// prefix) of THIS rock variant, so a
# broken-off half spawns the SAME scene (small/medium/large) instead of a hardcoded one.
func _scene_name() -> String:
	if scene_file_path != "":
		return scene_file_path.trim_prefix("res://")
	return "scenes/_universe/environment/terrain/rocks/rock_mining_sm.tscn"

func _server_create_side2_rock(cut_index: int, kick: Vector3) -> void:
	# Create the complementary half as its own networked rock. It inherits ALL our
	# faults (so it shows the remaining veins and can be split again), but the fault we
	# just cut is flipped to keep_side 2 so its box removes the other half instead.
	var bloc2_uuid = UUID_UTIL.v4()
	# Nudge the spawn off our half + carry a kick so it separates instead of overlapping.
	var spawn_pos: Vector3 = position + kick.normalized() * 0.2
	var side2_blocs := []
	for i in blocs.size():
		var bloc = blocs[i]
		var is_cut: bool = (i == cut_index)
		side2_blocs.append({
			"fractured": bloc.get("fractured", false),
			"number": bloc.get("number", 0),
			"position": bloc.position,
			"rotation_y": bloc.rotation_y,
			"rotation_z": bloc.rotation_z,
			"keep_side": 2 if is_cut else bloc.get("keep_side", 1),
			"side2_uuid": bloc2_uuid if is_cut else bloc.get("side2_uuid", ""),
		})

	var data := {
		"type": type_name,
		"uuid": bloc2_uuid,
		"position": {"x": spawn_pos.x, "y": spawn_pos.y, "z": spawn_pos.z},
		"rotation": {"x": rotation[0], "y": rotation[1], "z": rotation[2]},
		"blocs": side2_blocs,
		"kick": {"x": kick.x, "y": kick.y, "z": kick.z},
		"scenename": _scene_name(),
		# Same parent as ourselves (a known GORC id, or "" for root) so Horizon can
		# resolve it instead of queuing the side2 forever.
		"parent_id": created_parent_id,
		# Inherit our ore distribution seed so the piece's exterior stays continuous.
		"ore_seed": ore_seed if ore_seed != "" else uuid,
		# Inherit our mineral so the broken-off half shows the same ore (not the default gold).
		"mineral_id": str(mineral.id) if mineral != null else "",
	}
	# Register the side2 in Horizon (other players) AND create it locally on this game
	# server (so it can be simulated and re-cut). Horizon's GORC is players-only and does
	# not echo it back here. See NetworkOrchestrator.spawn_prop_authoritative.
	NetworkOrchestrator.spawn_prop_authoritative(data)

### Rock no longer breaks on body contact: the fracture is triggered by the mining
### tool (perforation along the targeted fault), handled server-side via an action.
func _on_area_3d_body_entered(_body: Node3D) -> void:
	pass
