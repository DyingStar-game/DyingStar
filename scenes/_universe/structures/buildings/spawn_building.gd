extends Node3D

signal hs_server_prop_update
signal hs_server_prop_delete

@export var uuid: String = ""
@export var apartments = {
	"total": 20,
	"available": 10,
	"side_number": 10,
	"sides": 1, # 1 or 2
	"floors_number": 3,
	"apartments": [
		{
			"floor": 0,
			"side": 1,
			"apartment_number": 2,
			"player_uuid": null,
			"player_name": null,
		},
	],
}


var type_name = "building"

var spawn_position: Vector3 = Vector3.ZERO
# Y component is used as an additional heading (yaw) in radians on top of surface alignment.
var spawn_rotation: Vector3 = Vector3.ZERO

var has_parent: bool = false


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# Buildings must not move: freeze so the physics engine never applies gravity
	# or forces to this body (prevents the building — and any player child — from drifting).
	position = spawn_position
	_align_to_surface(spawn_rotation.y)


## Aligns the building so its local +Y axis points away from the planet centre
## (i.e. along the surface normal at its position). An optional heading_rad
## rotates the building around that normal so you can control which way it faces.
func _align_to_surface(heading_rad: float = 0.0) -> void:
	var up := spawn_position.normalized()
	if up.is_zero_approx():
		return
	var forward := Vector3.FORWARD if abs(up.dot(Vector3.FORWARD)) < 0.99 else Vector3.RIGHT
	var right := up.cross(forward).normalized()
	var fwd := right.cross(up).normalized()
	basis = Basis(right, up, -fwd)
	if not is_zero_approx(heading_rad):
		basis = basis.rotated(up, heading_rad)


func _create_apartments():
	for f in range(apartments["floors_number"]):
		for i in range(apartments["side_number"]):
			# Don't duplicate on itself the apartment 001
			if f == 0 and i == 0:
				continue
			var node_apart = $MultiMeshInstance3D/building_apartment_001.duplicate()
			$MultiMeshInstance3D.add_child(node_apart)
			node_apart.position.z = i * 3.16
			node_apart.position.y = f * 3.25
		if apartments["sides"] == 2:
			for i in range(apartments["side_number"]):
				var node_apart = $MultiMeshInstance3D/building_apartment_001.duplicate()
				$MultiMeshInstance3D.add_child(node_apart)
				node_apart.rotation.y = 0
				node_apart.position.x = -5.16
				node_apart.position.z = i * 3.16
				node_apart.position.y = f * 3.25


func client_parent_change(parent: Node) -> void:
	reparent(parent)
	has_parent = true

func client_channel_data_update(data: Dictionary) -> void:
	if data.has("position"):
		spawn_position = Vector3(
			data["position"]["x"],
			data["position"]["y"],
			data["position"]["z"]
		)
		position = spawn_position
		_align_to_surface(spawn_rotation.y)

	if data.has("rotation"):
		spawn_rotation = Vector3(
			data["rotation"]["x"],
			data["rotation"]["y"],
			data["rotation"]["z"]
		)
		_align_to_surface(spawn_rotation.y)

	if data.has("apartments"):
		apartments = data["apartments"]
		_create_apartments()

func _exit_tree() -> void:
	if GameOrchestrator.is_server():
		emit_signal(
			"hs_server_prop_delete",
			uuid,
			type_name
		)
