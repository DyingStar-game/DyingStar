extends StaticBody3D

## Networked spawn building. Networking (uuid, replication, reparent, delete) lives in the PropSync
## child node (type_name "spawnbuilding", non-carriable); custom state (apartments/slots) is applied via
## apply_prop_data(). The body exposes `uuid` so it can be resolved as a networked parent by uuid.

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

var _apartments_created: bool = false

var _sync: PropSync

## Cached PropSync child, resolved lazily so a facade access before _ready still works.
func _prop_sync() -> PropSync:
	if _sync == null:
		_sync = PropSync.of(self)
	return _sync

var uuid: String:
	get:
		var s := _prop_sync()
		return s.uuid if s != null else ""
	set(value):
		var s := _prop_sync()
		if s != null:
			s.uuid = value


func _create_apartments():
	if _apartments_created:
		return
	_apartments_created = true
	for f in range(floors):
		for i in range(cols):
			# Don't duplicate on itself the apartment 001
			if f == 0 and i == 0:
				continue
			var node_apart = %"0-0-0".duplicate()
			node_apart.name = str("0-", i, "-", f)
			node_apart.position.z = i * z_spacing
			node_apart.position.y = f * y_spacing
			$MultiMeshInstance3D.add_child(node_apart)
		if rows == 2:
			for i in range(cols):
				var node_apart = %"0-0-0".duplicate()
				node_apart.name = str("1-", i, "-", f)
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


func _fill_pseudo_plate() -> void:
	for apt in apartments:
		var node_name := str(int(apt["row"]), "-", int(apt["col"]), "-", int(apt["floor"]))
		var node_apart := $MultiMeshInstance3D.get_node_or_null(node_name)
		if node_apart == null:
			continue

		var label3d := node_apart.get_node_or_null("Label3D") as Label3D
		if label3d == null:
			label3d = Label3D.new()
			label3d.name = "Label3D"
			label3d.position = Vector3(0.02, 1.22, 2.42)
			label3d.rotation_degrees = Vector3(0.0, 90.0, 0.0)
			label3d.pixel_size = 0.003
			label3d.font = load("res://ui/Poppins-BoldItalic.ttf")
			label3d.font_size = 12
			label3d.outline_size = 8
			label3d.modulate = Color(0.85, 1.0, 0.85, 1.0)
			label3d.outline_modulate = Color(0.0, 0.8, 0.05, 0.75)
			label3d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			label3d.double_sided = true
			node_apart.add_child(label3d)

		label3d.text = "HOME\n%s" % apt["player_name"]

## PropSync applies the replicated transform, then calls this with the full payload so the building can
## apply its own (non-transform) fields. Replaces the old client_channel_data_update override.
func apply_prop_data(data: Dictionary) -> void:
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
		if not GameOrchestrator.is_server():
			_fill_pseudo_plate()
