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

var bloc_yet_fractured: bool = false

var blocs = [
	{
		"fractured": false,
		"position": randf_range(0.0, 1.0),
		"rotation_y": randf_range(-50.0, 50.0),
		"rotation_z": randf_range(-50.0, 50.0),
		"keep_side": 1, # when cut a rock, we have 2 parts, we must indicate which part we keep
		"side2_uuid": ""
	}
]

@onready var rock_shape = $CollisionShape3D

func _ready() -> void:
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
	# add the material (1 = the cut part)
	var material = load("res://scenes/props/rock/rock_material.tres")
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
	pass

func client_parent_change(parent: Node) -> void:
	reparent(parent)
	has_parent = true

func client_channel_data_update(data: Dictionary) -> void:
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
	var parent = get_parent()
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
				"parent_id": parent.uuid,
			}
		]
	}
	ServerNetwork.send_message(message, "devmodecreate_object")

### When the mining tool used by the user enter in the area zone, we break the rock
func _on_area_3d_body_entered(body: Node3D) -> void:
	if OS.has_feature("dedicated_server"):
		# run cut the rock only for the player character enter in area zone
		if body is CharacterBody3D:
			for bloc in blocs:
				if bloc.fractured == false:
					_cut_rock(bloc)
					return

func _exit_tree() -> void:
	if GameOrchestrator.is_server():
		emit_signal(
			"hs_server_prop_delete",
			uuid,
			type_name
		)
