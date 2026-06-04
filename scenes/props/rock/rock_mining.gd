extends RigidBody3D

signal hs_server_prop_update
signal hs_server_prop_delete

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

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

var bloc_yet_fractured: bool = false

# Predefined faults (fixed, not random) — shown as red veins; perforating a vein
# cuts the rock along it. keep_side = which half we keep when cut (the other half
# becomes a new rock).
var blocs = [
	{ "fractured": false, "position": 0.35, "rotation_y": 18.0, "rotation_z": 12.0, "keep_side": 1, "side2_uuid": "" },
	{ "fractured": false, "position": 0.55, "rotation_y": -28.0, "rotation_z": 34.0, "keep_side": 1, "side2_uuid": "" },
	{ "fractured": false, "position": 0.70, "rotation_y": 42.0, "rotation_z": -22.0, "keep_side": 1, "side2_uuid": "" },
]

@onready var rock_shape = $CollisionShape3D

func _ready() -> void:
	add_to_group("miningrock")  # for proximity detection (aim mode)
	var item_rock_mesh = get_child(0) as CSGMesh3D
	combiner = CSGCombiner3D.new()
	add_child(combiner)

	await get_tree().process_frame

	rock_shape.shape = item_rock_mesh.mesh.create_convex_shape(true)

	item_rock_mesh.reparent(combiner)

	if OS.has_feature("dedicated_server"):
		_server_ready()
	else:
		_client_ready()

func _calculate_blocs() -> void:
	# create CSGbox3D
	for bloc in blocs:
		# generate the CSB box for subtraction
		bloc.instance = CSGBox3D.new()
		# define the size
		bloc.instance.size = Vector3(20.0, 20.0, 20.0)
		# set the rotation, we must do before move to have the same cut on both parts of the rock
		bloc.instance.rotation = Vector3(0.0, deg_to_rad(bloc.rotation_y), deg_to_rad(bloc.rotation_z))
		# apply the first translation to have the box on the extreme right of the rock
		bloc.instance.translate_object_local(Vector3(10.5, 0, 0))
		# translate to the random position
		bloc.instance.translate_object_local(Vector3(-bloc.position, 0.0, 0.0))
		if int(bloc.keep_side) == 2:
			# on bloc 2, we must move to the box x size to cut the another part
			bloc.instance.translate_object_local(Vector3(-20.0, 0, 0))
		bloc.instance.operation = CSGShape3D.OPERATION_SUBTRACTION
		if bloc.fractured == true and bloc_yet_fractured == false:
			_cut_rock(bloc)


# function to cut the rock
func _cut_rock(bloc: Dictionary) -> void:
	var create_part2_rock = false
	if int(bloc.keep_side) == 1 and bloc.fractured == false:
		create_part2_rock = true
	# we set the bloc to fractured, needed for the server sync
	bloc.fractured = true
	# add to the combiner for the substration operation
	combiner.add_child(bloc.instance)

	await get_tree().process_frame
	# create the mesh and collision shape
	var meshes = combiner.get_meshes()
	var mesh: Mesh = meshes[1]

	if mesh.get_surface_count() == 0:
		return

	# update center of mass
	var arraymesh = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var total = Vector3.ZERO
	for vertice in arraymesh:
		total += vertice
	var meshcenter = total / arraymesh.size()

	var meshinstance = MeshInstance3D.new()
	meshinstance.mesh = mesh
	# Keep the textured + veins material on the cut piece (remaining faults only).
	var material := _make_vein_material()
	meshinstance.set_surface_override_material(0, material)
	meshinstance.set_surface_override_material(1, material)
	add_child(meshinstance)

	rock_shape.shape = mesh.create_convex_shape(true)

	# send update for Horizon & clients
	var message1 = {
		"namespace": "props",
		"event": "position",
		"amessagenb": 1,
		"data": [
			{
				"type": "miningrock",
				"uuid": uuid,
				"blocs": [
					{
						"fractured": true,
						"position": bloc.position,
						"rotation_y": bloc.rotation_y,
						"rotation_z": bloc.rotation_z,
						"keep_side": 1,
						"side2_uuid": ""
					}
				],
			}
		]
	}
	ServerNetwork.send_message(message1, "prop_update")

	bloc_yet_fractured = true
	combiner.queue_free()

	# Spawn the broken-off half as its own networked rock (side2), parented under
	# the same GORC parent as us so Horizon can resolve it (see created_parent_id).
	if int(bloc.keep_side) == 1 and OS.has_feature("dedicated_server") and create_part2_rock == true:
		_server_create_side2_rock(bloc)

	meshinstance.position = -meshcenter
	rock_shape.position = -meshcenter
	position += meshcenter
	# disable freeze
	sleeping = false
	# can_sleep = false

#####################################################################
# Client part
######################################################################

func _client_ready() -> void:
	_show_faults()

## Show each not-yet-fractured fault as a red vein (a thin slice through the rock)
## at its cut plane, so faults are visible before perforating.
func _show_faults() -> void:
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
		normals.append(r * Vector3(1.0, 0.0, 0.0))   # fault plane normal (rock-local)
		offsets.append(0.5 - bloc.position)           # plane offset (rock-local)
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
		# _cut_rock() needs `combiner`, which is created in _ready(). When this
		# rock is spawned from the network, client_channel_data_update() is called
		# *before* the node enters the tree (see server/client.gd ~l.622), so
		# _ready() hasn't run yet and `combiner` is still null -> crash.
		# Wait until the node is ready before processing the blocs.
		if not is_node_ready():
			await ready
			await get_tree().process_frame  # let _ready() finish reparenting the mesh into combiner
		_calculate_blocs()

#####################################################################
# Server part
#####################################################################

func _server_ready() -> void:
	# send blocs to Horizon
	emit_signal(
		"hs_server_prop_update",
		uuid,
		{
			"blocs": blocs,
		},
		"miningrock",
		has_parent
	)
	_calculate_blocs()

## Server: perforate the fault nearest to `hit_local` (a rock-local point) and cut
## along it. One cut per rock for V0 (the CSG combiner is freed after a cut).
func server_perforate(hit_local: Vector3) -> void:
	if not OS.has_feature("dedicated_server") or bloc_yet_fractured:
		return
	var best_i := -1
	var best_d := INF
	for i in blocs.size():
		var bloc = blocs[i]
		if bloc.get("fractured", false):
			continue
		var r := Basis.from_euler(Vector3(0.0, deg_to_rad(bloc.rotation_y), deg_to_rad(bloc.rotation_z)))
		var n: Vector3 = r * Vector3(1.0, 0.0, 0.0)
		var d: float = absf(n.dot(hit_local) - (0.5 - bloc.position))
		if d < best_d:
			best_d = d
			best_i = i
	if best_i >= 0:
		_cut_rock(blocs[best_i])

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

func _server_create_side2_rock(bloc: Dictionary) -> void:
	# send the new prop to Horizon because create item must not be done directly on godot server
	var bloc2_uuid = UUID_UTIL.v4()

	var message = {
		"namespace": "props",
		"event": "create_object",
		"amessagenb": 1,
		"data": [
			{
				"type": type_name,
				"uuid": bloc2_uuid,
				"position": {
					"x": position[0],
					"y": position[1],
					"z": position[2]
				},
				"rotation": {
					"x": rotation[0],
					"y": rotation[1],
					"z": rotation[2]
				},
				"blocs": [
					{
						"fractured": true,
						"position": bloc.position,
						"rotation_y": bloc.rotation_y,
						"rotation_z": bloc.rotation_z,
						"keep_side": 2,
						"side2_uuid": bloc2_uuid
					}
				],
				"scenename": "scenes/props/rock/rock_mining_01.tscn",
				# Same parent as ourselves (a known GORC id, or "" for root): Horizon
				# can resolve it, so the side2 is spawned instead of queued forever.
				"parent_id": created_parent_id,
			}
		]
	}
	ServerNetwork.send_message(message, "devmodecreate_object")

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
