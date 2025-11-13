extends RigidBody3D

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

@export var uuid: String = ""

@onready var combiner = %CSGCombiner3D
@onready var origmesh = %CSGMesh3D

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_global_rotation = Vector3.ZERO

var blocs = [
	{
		"fractured": false,
		"position": randf_range(0.0, 1.0),
		"rotation": randf_range(-30.0, 30.0),
		"keep_side": 1,
		"side2_uuid": ""
	}
]

func _ready() -> void:
	# create CSGbox3D
	for bloc in blocs:
		# generate the CSB box for subtraction
		bloc.instance = CSGBox3D.new()
		# define the size
		bloc.instance.size = Vector3(20.0, 20.0, 20.0)
		# set the rotation, we must do before move to have the same cut on both parts of the rock
		bloc.instance.rotation = Vector3(0.0, 0.0, deg_to_rad(bloc.rotation))
		# apply the first translation to have the box on the extreme right of the rock
		bloc.instance.translate_object_local(Vector3(10.5, 0, 0))
		# translate to the random position
		bloc.instance.translate_object_local(Vector3(-bloc.position, 0.0, 0.0))
		if bloc.keep_side == 2:
			# on bloc 2, we must move to the box x size to cut the another part
			bloc.instance.translate_object_local(Vector3(-20.0, 0, 0))
		bloc.instance.operation = CSGShape3D.OPERATION_SUBTRACTION
		if bloc.fractured == true:
			_cut_rock(bloc)

	if OS.has_feature("dedicated_server"):
		_server_ready()
	else:
		_client_ready()

# function to cut the rock
func _cut_rock(bloc: Dictionary) -> void:
	var create_part2_rock = false
	if bloc.keep_side == 1 and bloc.fractured == false:
		create_part2_rock = true
	# we set the bloc to fractured, needed for the server sync
	bloc.fractured = true
	# add to the combiner for the substration operation
	combiner.add_child(bloc.instance)

	await get_tree().process_frame
	# create the mesh and collision shape
	var meshes = combiner.get_meshes()
	var mesh: Mesh = meshes[1]
	var collision_shape = combiner.bake_collision_shape()
	
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
	
	var collisioninstance = CollisionShape3D.new()
	collisioninstance.shape = collision_shape
	add_child(collisioninstance) 

	#meshinstance.center_of_mass = -meshcenter
	#collisioninstance.center_of_mass = -meshcenter
	
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
						"rotation": bloc.rotation,
						"keep_side": 1,
						"side2_uuid": ""
					}
				],
			}
		]
	}
	ServerNetwork.send_message(message1, "devmodecreate_object")

	combiner.queue_free()

	if bloc.keep_side == 1 and OS.has_feature("dedicated_server") and create_part2_rock == true:
		_server_create_side2_rock(bloc)

	meshinstance.position = -meshcenter
	collisioninstance.position = -meshcenter
	global_position = global_position + meshcenter
	center_of_mass = meshcenter

#####################################################################
# Definitions
######################################################################

## Channel 0:
# position
# rotation
# parent_id

## Channel 1:
# 

## Channel 2:
# weight
# blocs: [
#   {
#	    fractured: bool,
#       position: Vector3.ZERO,
#       rotation: Vector3.UP,
#	    keep_side: int # 1 = side1 (default value), 2 = side 2
#       side2_uuid: string
#   }
# ]


# when cut a rock, we have 2 parts, we must indicate which part we keep



#####################################################################
# Client part
######################################################################

func _client_ready() -> void:
	pass

func _client_channel_0() -> void:
	pass

func _client_channel_1() -> void:
	pass

func _client_channel_2() -> void:
	pass

func gorc_create(data: Dictionary) -> void:
	if data.has("object_data"):
		if data["object_data"].has("blocs"):
			blocs = data["object_data"]["blocs"]
			_ready()

#####################################################################
# Server part
#####################################################################

func _server_ready() -> void:
	pass


func _server_create_side2_rock(bloc: Dictionary) -> void:
		# we cut the bloc part 1, so now generate the bloc for the part 2
		var instance = load("res://scenes/props/rock/rock_mining_01.tscn").instantiate()
		instance.blocs = [
			{
				"fractured": true,
				"position": bloc.position,
				"rotation": bloc.rotation,
				"keep_side": 2,
				"side2_uuid": "" # will put uuid given by the server
			}
		]
		get_parent().add_child(instance)
		instance.reparent(get_parent())
		instance.position = position
		# send the new prop to Horizon
		var parent = get_parent()
		var bloc2_uuid = UUID_UTIL.v4()
		var message = {
			"namespace": "props",
			"event": "create_object",
			"amessagenb": 1,
			"data": [
				{
					"type": "miningrock",
					"uuid": bloc2_uuid,
					"position": {
						"x": instance.position[0],
						"y": instance.position[1],
						"z": instance.position[2]
					},
					"rotation": {
						"x": instance.rotation[0],
						"y": instance.rotation[1],
						"z": instance.rotation[2]
					},
					"blocs": [
						{
							"fractured": true,
							"position": bloc.position,
							"rotation": bloc.rotation,
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


func _on_area_3d_body_entered(body: Node3D) -> void:
	if OS.has_feature("dedicated_server"):
		# run cut the rock only for the player character enter in area zone
		if body is CharacterBody3D:
			for bloc in blocs:
				if bloc.fractured == false:
					_cut_rock(bloc)
					return
