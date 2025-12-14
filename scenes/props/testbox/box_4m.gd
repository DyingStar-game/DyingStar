class_name Box4m

extends RigidBody3D

signal hs_server_prop_update
signal hs_server_prop_delete

@export var inside_space: World3D

@export var uuid: String = ""

var type_name = "box"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_rotation = Vector3.ZERO

var has_parent: bool = false

func _ready() -> void:
	$Area3D.body_entered.connect(_on_box_entered)
	$Area3D.body_exited.connect(_on_box_exited)

	global_position = spawn_position
	global_rotation = spawn_rotation

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
				"box",
				has_parent
			)
			server_last_position = my_position
			server_last_rotation = my_rotation

func _on_box_entered(body: Node3D):
	if body.is_in_group("containable"):
		if not body.is_inside_box4m:
			body.set_collision_layer_value(1, false)
			body.set_collision_layer_value(2, true)
			body.set_collision_mask_value(1, false)
			body.set_collision_mask_value(2, true)
			body.is_inside_box4m = true

func _on_box_exited(body: Node3D):
	if body.is_in_group("containable"):
		if body.is_inside_box4m:
			body.set_collision_layer_value(2, false)
			body.set_collision_layer_value(1, true)
			body.set_collision_mask_value(2, false)
			body.set_collision_mask_value(1, true)
			body.is_inside_box4m = false

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

func _exit_tree() -> void:
	if GameOrchestrator.is_server():
		emit_signal(
			"hs_server_prop_delete",
			uuid,
			type_name
		)
