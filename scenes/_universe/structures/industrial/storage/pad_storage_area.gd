@tool
class_name PadStorageArea
extends Node3D

## A storage area: a stretch of levelled ground (its TerrainPad) that things stand on as its CHILDREN,
## containers first. Place it in a layout (ares_village_mining, ares_city_factory), size it in the
## Inspector, and drop the containers under it: poi_villages.gd spawns them with the area as their
## parent, their pose local to it. The server seats the area on the ground it levels, and they move
## with it; placed beside it instead, they would keep the layout's height while the ground under them
## settled 16 cm away on average, more than 50 cm one time in five (measured on 5 726 buildings).
##
## The size travels with the area (`size` in storage_area_def.json): a value set only on the layout's
## node would reach no client, each machine building the object from its scene file and its replicated
## properties, and the server and the clients would level different ground.

## Smallest side of an area, in metres.
const MIN_SIDE_M := 1.0

## Width (local X) and length (local Z) of the levelled ground, in metres. TerrainPad's apron adds a
## flat margin around it.
@export var size: Vector2 = Vector2(20.0, 12.0):
	set(value):
		size = Vector2(maxf(value.x, MIN_SIDE_M), maxf(value.y, MIN_SIDE_M))
		_resize()

var _sync: PropSync

## The network uuid, read off the PropSync child: what a child reads (PropSpawn.parent_frame_uuid) to
## publish its pose in this area's frame.
var uuid: String:
	get:
		var s := _prop_sync()
		return s.uuid if s != null else ""
	set(value):
		var s := _prop_sync()
		if s != null:
			s.uuid = value


func _enter_tree() -> void:
	# Before the TerrainPad child's own _enter_tree: it reads its marker box there. The size an
	# instance sets in a layout is applied before the children exist, so the box is fitted here.
	_resize()


## The replicated fields beyond the pose (PropSync calls it with the whole payload, before the area
## enters the tree on a spawn: the flattener then reads a box of the right size).
func apply_prop_data(data: Dictionary) -> void:
	if data.has("size"):
		size = _vector2(data["size"])


func _prop_sync() -> PropSync:
	if _sync == null:
		_sync = PropSync.of(self)
	return _sync


## The TerrainPad footprint of an area of [param data]'s size, local to the TerrainPad node ({size,
## local}, what its marker box would hold): 1 m thick, its top face at the area's origin. Static so the
## server can state the pad of an area that has no node yet (server.gd _stream_register_pads) with the
## same numbers; the scene's 20 x 12 m box would state a second, different record for the same ground.
static func terrain_pad_box(data: Dictionary) -> Dictionary:
	var side := _vector2(data.get("size", Vector2(20.0, 12.0)))
	return {
		"size": Vector3(maxf(side.x, MIN_SIDE_M), 1.0, maxf(side.y, MIN_SIDE_M)),
		"local": Transform3D(Basis.IDENTITY, Vector3(0.0, -0.5, 0.0)),
	}


## Fit the TerrainPad to the area's size (TerrainPad.set_footprint also resizes its marker box while
## it exists, so the one it reads on entering the tree holds the same numbers).
func _resize() -> void:
	var pad := get_node_or_null("TerrainPad") as TerrainPad
	if pad == null:
		return
	var box := terrain_pad_box({"size": size})
	pad.set_footprint(box["size"], box["local"])


## A Vector2 from the network's {x, y} (or a Vector2 already).
static func _vector2(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Dictionary:
		return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
	return Vector2.ZERO
