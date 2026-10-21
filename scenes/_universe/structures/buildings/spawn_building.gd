class_name SpawnBuilding
extends NetStaticBody  # the uuid facade (see NetStaticBody)

## Networked spawn building. Networking (uuid, replication, reparent, delete) lives in the PropSync
## child node (type_name "spawnbuilding", non-carriable); custom state (apartments/slots) is applied via
## apply_prop_data(). The body exposes `uuid` so it can be resolved as a networked parent by uuid.

## Number of apartment rows: 1 or 2 (the second row is turned to face the first).
@export var rows: int = 1
## Number of apartments per row, along +Z (from 1).
@export var cols: int = 1
## Number of storeys (from 1).
@export var floors: int = 1
## Apartment depth along X (m): a habitat container's length. Negative = rows extend towards -X; the
## second row sits at twice this offset.
@export var x_spacing: float = -6.1
## Distance (m) between two neighbouring apartments of a row, along Z: a container's width.
@export var z_spacing: float = 2.6
## Height (m) of one storey: the distance between two floors, a container's height.
@export var y_spacing: float = 2.6
## Player spawn in apartment 0-0-0, local to the building: Horizon offsets it for each slot. At the
## middle of the container, the free floor between the bed and the wardrobe: Horizon mirrors it in the
## other slots, and the middle is its own mirror.
@export var spawn_point: Vector3 = Vector3(-3.05, 0.15, 1.3)
## uuid of the poi_village this building belongs to ("" = none): Horizon fills villages by it.
@export var poi_uuid: String = ""

## Occupied apartments, as {floor, row, col, player_uuid, player_name}: each shows its occupant's name
## on its door plate.
## Replicated from the server; the default is a test entry.
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
## The furniture of its apartments someone set (FurnitureState): replicated as `furniture`.
var furniture: Dictionary:
	get:
		return _furniture.state

var _apartments_created: bool = false
var _furniture := FurnitureState.new()

## Margin of the levelled footprint past the walls, as in the box drawn in the scene.
const PAD_MARGIN_M := 0.5


## The TerrainPad footprint of a building of [param data]'s rows / cols / spacings, local to the
## TerrainPad node ({size, local}, what its marker box would hold). Static so the server can state the
## pad of a building that has no node yet (server.gd _stream_register_pads) with the same numbers.
## Apartments run from x = 0 towards −x (one or two rows) and from z = 0 towards +z (cols).
static func terrain_pad_box(data: Dictionary) -> Dictionary:
	var w: float = float(data.get("rows", 1)) * absf(float(data.get("x_spacing", -6.1)))
	var l: float = float(data.get("cols", 1)) * absf(float(data.get("z_spacing", 2.6)))
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
			node_apart.name = slot_name({"row": 0, "col": i, "floor": f})
			node_apart.position.z = i * z_spacing
			node_apart.position.y = f * y_spacing
			$MultiMeshInstance3D.add_child(node_apart)
		if rows == 2:
			for i in range(cols):
				var node_apart = %"0-0-0".duplicate()
				node_apart.name = slot_name({"row": 1, "col": i, "floor": f})
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


## The name of the apartment slot [param apt] ({floor, row, col}): "<row>-<col>-<floor>", as the
## copies of 0-0-0 are named.
static func slot_name(apt: Dictionary) -> String:
	return str(int(apt["row"]), "-", int(apt["col"]), "-", int(apt["floor"]))


## The apartment (a copy of 0-0-0) [param node] stands in, or null when it is in none.
func apartment_of(node: Node) -> Node:
	var rooms: Node = get_node_or_null("MultiMeshInstance3D")
	while node != null and node.get_parent() != rooms:
		node = node.get_parent()
	return node


## True when [param surface] -- a body a load would be put down on -- is in an apartment
## [param player_uuid] does not live in (a neighbour's, a free one): a home is its occupant's.
static func is_foreign_home(surface: Node, player_uuid: String) -> bool:
	var home := MarkerSpawn.building_of(surface) as SpawnBuilding if surface != null else null
	if home == null:
		return false
	var room: Node = home.apartment_of(surface)
	return room != null and home.occupant_of(room) != player_uuid


## The player_uuid of whoever lives in [param apartment], "" when it is free.
func occupant_of(apartment: Node) -> String:
	if apartment == null:
		return ""
	for apt in apartments:
		if slot_name(apt) == str(apartment.name):
			return str(apt.get("player_uuid", ""))
	return ""


## SERVER: a validated use of [param part] (PlayerServer "furniture_use"): set it [param on], show it
## here (a door's body moves with it) and replicate the new state.
func server_set_part(part: ToggledPart, on: bool) -> void:
	PropSync.of(self).server_prop_update({"furniture": _furniture.set_part(part, on, _rooms())})


## SERVER: an NPC living in one of the apartments was placed in the building: open its home's doors that
## open for an NPC (MovingPart.opens_for_npc), so it is not shut in -- an NPC never opens one. Kept like
## any use: replicated, and the door stays open across restarts.
func server_open_for_npc(npc_uuid: String) -> void:
	for apt in apartments:
		if str(apt.get("player_uuid", "")) != npc_uuid:
			continue
		var room: Node = get_node_or_null("MultiMeshInstance3D/" + slot_name(apt))
		if room == null:
			continue
		for door: MovingPart in FurnitureState.npc_doors(room):
			if not bool(furniture.get(door.state_key(), false)):
				server_set_part(door, true)


## The apartments' parent, once they exist (null before: the furniture's state waits for them).
func _rooms() -> Node:
	return get_node_or_null("MultiMeshInstance3D") if _apartments_created else null


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
			ApartmentPlates.show($MultiMeshInstance3D, apartments, uuid, Player.own_horizon_id())

	if data.get("furniture") is Dictionary:
		_furniture.receive(data["furniture"], _rooms())
	elif data.has("apartments"):
		_furniture.show_once(_rooms())
