extends RigidBody3D

signal hs_server_prop_update
signal hs_server_prop_delete

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

@export var uuid: String = ""

var type_name = "miningrock"

var combiner: CSGCombiner3D

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_rotation = Vector3.ZERO

var has_parent: bool = false

# The parent we were created under (a valid GORC id, or "" for a root object).
# Reused for the broken-off half (side2) so Horizon can resolve its parent too:
# a non-empty parent_id that Horizon doesn't know is queued forever (never spawned).
var created_parent_id: String = ""

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
# Velocity to apply once when this piece spawns, to push it off the half it split from.
var _spawn_kick: Vector3 = Vector3.ZERO

@onready var rock_shape = $CollisionShape3D

func _ready() -> void:
	add_to_group("miningrock")  # for proximity detection (aim mode)
	var item_rock_mesh = get_child(0) as CSGMesh3D
	_base_mesh = item_rock_mesh.mesh   # keep a ref to rebuild cuts later
	if _base_mesh != null:
		_mesh_center = _base_mesh.get_aabb().get_center()   # true middle of the rock
	combiner = CSGCombiner3D.new()
	add_child(combiner)

	await get_tree().process_frame

	rock_shape.shape = item_rock_mesh.mesh.create_convex_shape(true)

	item_rock_mesh.reparent(combiner)

	if OS.has_feature("dedicated_server"):
		_server_ready()
	else:
		_client_ready()

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
	box.size = Vector3(20.0, 20.0, 20.0)
	# rotate before translating so the cut plane matches on both halves
	box.rotation = Vector3(0.0, deg_to_rad(bloc.rotation_y), deg_to_rad(bloc.rotation_z))
	box.translate_object_local(Vector3(10.5, 0, 0))        # box on the far right of the rock
	box.translate_object_local(Vector3(-bloc.position, 0.0, 0.0))
	# Shift the cut plane onto the mesh center (along the fault normal) so position 0.5
	# is the true middle even when the mesh origin is off-center.
	var n: Vector3 = Basis.from_euler(Vector3(0.0, deg_to_rad(bloc.rotation_y), deg_to_rad(bloc.rotation_z))) * Vector3(1.0, 0.0, 0.0)
	box.translate_object_local(Vector3(n.dot(_mesh_center), 0.0, 0.0))
	if int(bloc.keep_side) == 2:
		box.translate_object_local(Vector3(-20.0, 0, 0))   # cut the other half instead
	box.operation = CSGShape3D.OPERATION_SUBTRACTION
	return box

## Rebuild the rock mesh = base mesh minus EVERY fractured fault. Always rebuilt from
## scratch, so it is idempotent (replaying the same fault set changes nothing) and
## supports several cuts on the same rock: a half can be split again -> down to 4 pieces.
func _rebuild() -> void:
	if _base_mesh == null:
		return
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
	# The first cut replaces the initial full-rock combiner with the baked mesh.
	if combiner != null and is_instance_valid(combiner):
		combiner.queue_free()
		combiner = null
	if _mesh_instance == null or not is_instance_valid(_mesh_instance):
		_mesh_instance = MeshInstance3D.new()
		add_child(_mesh_instance)
	_mesh_instance.mesh = mesh
	var material := _make_vein_material()   # remaining (un-fractured) faults stay visible
	_mesh_instance.set_surface_override_material(0, material)
	_mesh_instance.set_surface_override_material(1, material)
	rock_shape.shape = mesh.create_convex_shape(true)
	# No manual recenter: each piece keeps the rock's transform and occupies its own
	# half of the original volume (Godot derives the rigid body's center of mass from
	# the offset shape). This keeps both halves in place instead of teleporting them.
	sleeping = false
	# Server only: kick this piece off the half it split from (set once on spawn).
	if GameOrchestrator.is_server() and _spawn_kick != Vector3.ZERO:
		linear_velocity += _spawn_kick
		_spawn_kick = Vector3.ZERO

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

## Show each not-yet-fractured fault as a red vein (a thin slice through the rock)
## at its cut plane, so faults are visible before perforating.
func _show_faults() -> void:
	if combiner == null or not is_instance_valid(combiner):
		return   # already cut: the veins live on the rebuilt mesh instead
	var mesh_node = combiner.get_child(0) if combiner.get_child_count() > 0 else null
	if mesh_node is CSGMesh3D:
		(mesh_node as CSGMesh3D).material = _make_vein_material()

## Rock material that draws red veins where the surface is near a not-yet-fractured
## fault plane (intersection only -> crack lines, nothing sticking out).
func _make_vein_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://scenes/props/rock/rock_vein.gdshader")
	mat.set_shader_parameter("albedo_tex", preload("res://assets/textures/grounds/rock/Rock029_2K_Color.jpg"))
	mat.set_shader_parameter("tex_scale", 1.0)
	var normals: Array = []
	var offsets: Array = []
	for bloc in blocs:
		if bloc.get("fractured", false):
			continue
		var r := Basis.from_euler(Vector3(0.0, deg_to_rad(bloc.rotation_y), deg_to_rad(bloc.rotation_z)))
		var n: Vector3 = r * Vector3(1.0, 0.0, 0.0)
		normals.append(n)                                            # fault plane normal (rock-local)
		offsets.append((0.5 - bloc.position) + n.dot(_mesh_center))  # plane offset, centered on the mesh
	mat.set_shader_parameter("plane_count", normals.size())
	mat.set_shader_parameter("plane_normals", normals)
	mat.set_shader_parameter("plane_offsets", offsets)
	return mat

func client_parent_change(parent: Node) -> void:
	reparent(parent)
	has_parent = true

func client_channel_data_update(data: Dictionary) -> void:
	if data.has("parent_id"):
		created_parent_id = str(data["parent_id"])
	if data.has("kick"):
		_spawn_kick = Vector3(data["kick"]["x"], data["kick"]["y"], data["kick"]["z"])
	if data.has("position"):
		position = Vector3(
			data["position"]["x"],
			data["position"]["y"],
			data["position"]["z"]
		)
	if data.has("rotation"):
		rotation = Vector3(
			data["rotation"]["x"],
			data["rotation"]["y"],
			data["rotation"]["z"]
		)
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
# Server part
#####################################################################

func _server_ready() -> void:
	# send blocs to Horizon
	emit_signal(
		"hs_server_prop_update",
		uuid,
		{
			"blocs": _blocs_payload(),
		},
		"miningrock",
		has_parent
	)
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
		if d <= FAULT_HIT_THRESHOLD:
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
	if best_d > FAULT_HIT_THRESHOLD:
		return   # the aim point isn't on any fault -> nothing happens
	# Intersection priority: when the aim point sits on the crossing of several faults
	# (their distances are nearly tied), cut the one with the LOWEST number.
	var best_number: int = int(blocs[best_i].get("number", 9999))
	for i in dists:
		if dists[i] <= best_d + INTERSECTION_MARGIN:
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

func _physics_process(_delta: float) -> void:
	if GameOrchestrator.is_server():
		var my_position = snapped(position, Vector3(0.001, 0.001, 0.001))
		var my_rotation = snapped(rotation, Vector3(0.0001, 0.0001, 0.0001))
		if server_last_position != my_position or server_last_rotation != my_rotation:
			emit_signal(
				"hs_server_prop_update",
				uuid,
				{
					"position": my_position,
					"rotation": my_rotation,
				},
				type_name,
				has_parent
			)
			server_last_position = my_position
			server_last_rotation = my_rotation

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
		"scenename": "scenes/props/rock/rock_mining_01.tscn",
		# Same parent as ourselves (a known GORC id, or "" for root) so Horizon can
		# resolve it instead of queuing the side2 forever.
		"parent_id": created_parent_id,
	}
	# 1) Register the side2 in Horizon (GORC) so the OTHER players receive it. Horizon
	#    keeps spawn_in_gameserver=false: GORC is players-only, so it does NOT send the
	#    object back to this game server — we create it ourselves just below.
	ServerNetwork.send_message({
		"namespace": "props", "event": "create_object", "amessagenb": 1, "data": [data],
	}, "devmodecreate_object")
	# 2) Create the side2 locally on THIS game server (Horizon won't, see above), so it
	#    can be simulated and re-cut. Same path as a Horizon-spawned prop (instantiate +
	#    miningrock group + props_list + hs_server_prop_update wiring).
	NetworkOrchestrator.network_agent.create_generic_object({
		"data": {"object_uuid": bloc2_uuid, "object_type": type_name, "object_data": data},
	})

### Rock no longer breaks on body contact: the fracture is triggered by the mining
### tool (perforation along the targeted fault), handled server-side via an action.
func _on_area_3d_body_entered(_body: Node3D) -> void:
	pass

func _exit_tree() -> void:
	if GameOrchestrator.is_server():
		emit_signal(
			"hs_server_prop_delete",
			uuid,
			type_name
		)
