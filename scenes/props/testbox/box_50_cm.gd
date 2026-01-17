class_name Box50cm

extends RigidBody3D

signal hs_server_prop_update
signal hs_server_prop_delete

@export var uuid: String = ""

var type_name = "box"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_rotation = Vector3.ZERO

var has_parent: bool = false
var server_reparenting: bool = false

@onready var is_inside_box4m: bool = false

#func _ready() -> void:
	#position = spawn_position

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

func send_properties_to_client(parent_uuid: String) -> void:
	var my_position = snapped(position, Vector3(0.001, 0.001, 0.001))
	var my_rotation = snapped(rotation, Vector3(0.0001, 0.0001, 0.0001))
	emit_signal(
		"hs_server_prop_update",
		uuid,
		{
			"position": my_position,
			"rotation": my_rotation,
			"parent_id": parent_uuid,
			"weight": 200,
		},
		type_name,
		has_parent
	)
	print("REPARENT POSITION (1): %s" % my_position)
	server_last_position = my_position
	server_last_rotation = my_rotation

func _exit_tree() -> void:
	if GameOrchestrator.is_server() and server_reparenting == false:
		emit_signal(
			"hs_server_prop_delete",
			uuid,
			type_name
		)

func _enter_tree() -> void:
	if GameOrchestrator.is_server():
		print("REPARENT POSITION (2): %s" % position)
		server_reparenting = false

func client_parent_change(parent: Node) -> void:
	reparent(parent)
	has_parent = true

func server_parent_change(parent: Node) -> void:
	server_reparenting = true
	reparent(parent)

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

func interact(_interactor: Node = null):
	return true
