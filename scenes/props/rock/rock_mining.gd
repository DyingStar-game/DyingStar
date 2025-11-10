extends RigidBody3D

@export var uuid: String = ""

@onready var cutCube = %CSGBox3D
@onready var cutCube2 = %CSGBox3D2
@onready var combiner = %CSGCombiner3D

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_global_rotation = Vector3.ZERO

func _ready() -> void:
	cutCube.position = Vector3(randf_range(2.2, 3.0), 0, 0)
	cutCube.rotation_degrees = Vector3(0, 0, randf_range(-30, 30))
	#cutCube2.position = Vector3(randf_range(2.6, 3.8), 0, 0)
	#cutCube2.rotation_degrees = Vector3(0, -41.0, randf_range(-30, 30))

	await get_tree().process_frame
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
	add_child(meshinstance)
	
	var collisioninstance = CollisionShape3D.new()
	collisioninstance.shape = collision_shape
	add_child(collisioninstance) 
	
	meshinstance.position = -meshcenter
	collisioninstance.position = -meshcenter
	
	combiner.queue_free()
