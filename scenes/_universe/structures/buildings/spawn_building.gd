extends StaticBody3D

signal hs_server_prop_update
signal hs_server_prop_delete

@export var uuid: String = ""
@export var rows: int = 1 # 1 or 2
@export var cols: int = 1 # from 1
@export var floors: int = 1 # from 1
@export var x_spacing: float = -5.16
@export var z_spacing: float = 3.16
@export var y_spacing: float = 3.25

@export var apartments = [
	{
		"floor": 0,
		"row": 1,
		"col": 2,
		"player_uuid": "bdce5467-59f0-4897-8856-6dc2b1902584",
		"player_name": "player_test",
	},
]

var total: int = 1
var available: int = 0

var type_name = "spawnbuilding"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.ZERO

var server_last_position = Vector3.ZERO
var server_last_rotation = Vector3.ZERO

var has_parent: bool = false


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# Buildings must not move: freeze so the physics engine never applies gravity
	# or forces to this body (prevents the building — and any player child — from drifting).
	position = spawn_position
	# _align_to_surface(spawn_rotation.y)

func update_position_rotation() -> void:
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

## Aligns the building so its local +Y axis points away from the planet centre
## (i.e. along the surface normal at its position). An optional heading_rad
## rotates the building around that normal so you can control which way it faces.
# func _align_to_surface(heading_rad: float = 0.0) -> void:
# 	if OS.has_feature("dedicated_server"):
# 		var up := spawn_position.normalized()
# 		if up.is_zero_approx():
# 			return
# 		var forward := Vector3.FORWARD if abs(up.dot(Vector3.FORWARD)) < 0.99 else Vector3.RIGHT
# 		var right := forward.cross(up).normalized()
# 		var fwd := up.cross(right).normalized()
# 		basis = Basis(right, up, -fwd)
# 		if not is_zero_approx(heading_rad):
# 			basis = basis.rotated(up, heading_rad)
# 		update_position_rotation()


func _create_apartments():
	for f in range(floors):
		for i in range(cols):
			# Don't duplicate on itself the apartment 001
			if f == 0 and i == 0:
				continue
			var node_apart = %"1-0-0".duplicate()
			node_apart.name = str("1-", i, "-", f)
			node_apart.position.z = i * z_spacing
			node_apart.position.y = f * y_spacing
			$MultiMeshInstance3D.add_child(node_apart)
		if rows == 2:
			for i in range(cols):
				var node_apart = %"1-0-0".duplicate()
				node_apart.name = str("2-", i, "-", f)
				node_apart.rotation.y = 3.14159
				node_apart.position.x = (x_spacing * 2.0)
				node_apart.position.z = ((i + 1) * z_spacing)
				node_apart.position.y = f * y_spacing
				$MultiMeshInstance3D.add_child(node_apart)

	# update Area3D for reparent the player
	var shape_area = %CollisionShape3D as CollisionShape3D
	var new_shape := BoxShape3D.new()
	new_shape.size = Vector3(
		rows * abs(x_spacing),
		floors * abs(y_spacing),
		cols * abs(z_spacing)
	)
	shape_area.shape = new_shape
	shape_area.position = Vector3(
		-((rows * abs(x_spacing)) / 2.0),
		((floors * abs(y_spacing)) / 2.0),
		((cols * abs(z_spacing)) / 2.0),
	)


func _fill_pseudo_plate():
	pass
	# create sprite3D
	# add texture ViewportTexture
	# assign my subviewport
	# x: -2.601 y: 1.175, z: -0.788
	# rot: x: 0.0, y: -90.0, z: 0.0
	# scale: 0.18

func client_parent_change(parent: Node) -> void:
	reparent(parent)
	has_parent = true

func client_channel_data_update(data: Dictionary) -> void:
	# print("DATA UPDATE: %s" % data)
	if data.has("position"):
		spawn_position = Vector3(
			data["position"]["x"],
			data["position"]["y"],
			data["position"]["z"]
		)
		position = spawn_position

	if data.has("rotation"):
		spawn_rotation = Vector3(
			data["rotation"]["x"],
			data["rotation"]["y"],
			data["rotation"]["z"]
		)
		rotation = spawn_rotation
		# _align_to_surface(spawn_rotation.y)

	if data.has("name"):
		name = data["name"]

	if data.has("total"):
		total = data["total"]

	if data.has("available"):
		available = data["available"]

	if data.has("cols"):
		cols = data["cols"]

	if data.has("rows"):
		rows = data["rows"]

	if data.has("floors"):
		floors = data["floors"]

	if data.has("x_spacing"):
		x_spacing = data["x_spacing"]

	if data.has("z_spacing"):
		z_spacing = data["z_spacing"]

	if data.has("y_spacing"):
		y_spacing = data["y_spacing"]

	if data.has("apartments"):
		apartments = data["apartments"]
		_create_apartments()
		_fill_pseudo_plate()

func _exit_tree() -> void:
	if GameOrchestrator.is_server():
		emit_signal(
			"hs_server_prop_delete",
			uuid,
			type_name
		)
