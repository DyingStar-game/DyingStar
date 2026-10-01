extends NetStaticBody  # the uuid facade (see NetStaticBody)

## Networked spawn building. Networking (uuid, replication, reparent, delete) lives in the PropSync
## child node (type_name "spawnbuilding", non-carriable); custom state (apartments/slots) is applied via
## apply_prop_data(). The body exposes `uuid` so it can be resolved as a networked parent by uuid.

@export var rows: int = 1 # 1 or 2
@export var cols: int = 1 # from 1
@export var floors: int = 1 # from 1
@export var x_spacing: float = -5.16
@export var z_spacing: float = 3.16
@export var y_spacing: float = 3.25
## Player spawn in apartment 0-0-0, local to the building: Horizon offsets it for each slot.
@export var spawn_point: Vector3 = Vector3(-1.934, 0.071, 1.471)
## uuid of the poi_village this building belongs to ("" = none): Horizon fills villages by it.
@export var poi_uuid: String = ""

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

## Margin of the levelled footprint past the walls, as in the box drawn in the scene.
const PAD_MARGIN_M := 0.5


## The TerrainPad footprint of a building of [param data]'s rows / cols / spacings, local to the
## TerrainPad node ({size, local}, what its marker box would hold). Static so the server can state the
## pad of a building that has no node yet (server.gd _stream_register_pads) with the same numbers.
## Apartments run from x = 0 towards −x (one or two rows) and from z = 0 towards +z (cols).
static func terrain_pad_box(data: Dictionary) -> Dictionary:
	var w: float = float(data.get("rows", 1)) * absf(float(data.get("x_spacing", -5.16)))
	var l: float = float(data.get("cols", 1)) * absf(float(data.get("z_spacing", 3.16)))
	return {
		"size": Vector3(w + 2.0 * PAD_MARGIN_M, 0.2, l + 2.0 * PAD_MARGIN_M),
		"local": Transform3D(Basis.IDENTITY, Vector3(-0.5 * w, 0.0, 0.5 * l)),
	}


## Fit the TerrainPad to the building as it is now: the box drawn in the scene is one size for all
## of them (53 m long), which levelled the ground of the neighbours of a short building — at THEIR
## altitude, half a building floating or buried on a slope — and not the far end of a long one.
func _fit_terrain_pad() -> void:
	var pad := get_node_or_null("TerrainPad") as TerrainPad
	if pad == null:
		return
	var box := terrain_pad_box({"rows": rows, "cols": cols, "x_spacing": x_spacing,
			"z_spacing": z_spacing})
	pad.set_footprint(box["size"], box["local"])


func _enter_tree() -> void:
	# Before the TerrainPad child's own _enter_tree: it reads the marker box there.
	_fit_terrain_pad()



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

	if data.has("poi_uuid"):
		poi_uuid = data["poi_uuid"]

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

	_fit_terrain_pad()

	if data.has("apartments"):
		apartments = data["apartments"]
		_create_apartments()
		if not GameOrchestrator.is_server():
			_fill_pseudo_plate()
