extends StaticBody3D

signal hs_server_prop_update
signal hs_server_prop_delete

@export var uuid: String = ""

var type_name = "city"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_rotation = Vector3.ZERO

var has_parent: bool = false

func _ready() -> void:
	position = spawn_position
	_align_to_surface(spawn_rotation.y)

## Aligns the building so its local +Y axis points away from the planet centre
## (i.e. along the surface normal at its position). An optional heading_rad
## rotates the building around that normal so you can control which way it faces.
func _align_to_surface(heading_rad: float = 0.0) -> void:
	if OS.has_feature("dedicated_server"):
		print("==========================================YOLO=")
		print(position)
		print(rotation)
		print(scale)
		var up := spawn_position.normalized()
		if up.is_zero_approx():
			return
		var forward := Vector3.FORWARD if abs(up.dot(Vector3.FORWARD)) < 0.99 else Vector3.RIGHT
		var right := forward.cross(up).normalized()
		var fwd := up.cross(right).normalized()
		basis = Basis(right, up, -fwd)
		if not is_zero_approx(heading_rad):
			basis = basis.rotated(up, heading_rad)
		print("==========================================Yipi=")
		print(position)
		print(rotation)
		print(scale)
		send_properties_to_client()

func send_properties_to_client() -> void:
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
			true
		)
		server_last_position = my_position
		server_last_rotation = my_rotation

func client_parent_change(parent: Node) -> void:
	reparent(parent)
	has_parent = true

func client_channel_data_update(data: Dictionary) -> void:
	print("chennel")
	print(data)
	if data.has("position"):
		position = Vector3(
			data["position"]["x"],
			data["position"]["y"],
			data["position"]["z"]
		)
		spawn_position = position 
	if data.has("rotation"):
		rotation = Vector3(
			data["rotation"]["x"],
			data["rotation"]["y"],
			data["rotation"]["z"]
		)
		_align_to_surface(spawn_rotation.y)

func _exit_tree() -> void:
	if GameOrchestrator.is_server():
		emit_signal(
			"hs_server_prop_delete",
			uuid,
			type_name
		)
