@tool
extends "res://scenes/_universe/props/containers/generic_storagebox.gd"

## A vehicle test ramp: a road that climbs at angle_deg, runs flat on top, then comes down at the same
## angle, with a sign at each foot giving the grade. Everything is built from code when the ramp loads,
## so one script serves every grade.
##
## Networked like the containers (PropSync "simple_building"): a client builds it from its scene file
## alone, so an angle set on a layout node would reach no client. Each grade is therefore its own scene
## inheriting slope_ramp.tscn (slope_ramp_25.tscn sets angle_deg = 25).
##
## The road runs along local X, centred on the origin, its feet at ground level (y = 0).

## Marks the nodes built here, so a rebuild (editor tweak) frees them and they are never saved.
const GENERATED := "slope_ramp_generated"

## Grade of both slopes, in degrees.
@export_range(1.0, 60.0, 0.5) var angle_deg: float = 15.0:
	set(value):
		angle_deg = value
		_rebuild_deferred()
## Highest the flat top may rise above the ground (m). A gentle grade is kept lower so the whole ramp
## fits in max_length_m.
@export var max_height_m: float = 5.0:
	set(value):
		max_height_m = value
		_rebuild_deferred()
## Longest the ramp may be from foot to foot (m).
@export var max_length_m: float = 90.0:
	set(value):
		max_length_m = value
		_rebuild_deferred()
## Width of the road (m).
@export var width_m: float = 8.0:
	set(value):
		width_m = value
		_rebuild_deferred()
## Length of the flat top (m): room to stop, or to turn round.
@export var plateau_m: float = 10.0:
	set(value):
		plateau_m = value
		_rebuild_deferred()
## How far the base reaches below the ground (m), so no step opens at a foot where the ground is not
## quite level.
@export var bury_m: float = 0.3:
	set(value):
		bury_m = value
		_rebuild_deferred()

var _rebuild_queued: bool = false


func _ready() -> void:
	_rebuild()


## Height of the flat top and horizontal run of each slope (m), as Vector2(height, run): as high as
## [param max_height], lower when the two slopes and the plateau would not fit in [param max_length].
static func profile(angle: float, max_height: float, max_length: float, plateau: float) -> Vector2:
	var t: float = tan(deg_to_rad(clampf(angle, 0.1, 89.0)))
	var room: float = maxf((max_length - plateau) * 0.5, 0.0)
	var height: float = minf(maxf(max_height, 0.0), room * t)
	return Vector2(height, height / t)


## The road's cross-section along X (x, y): up, flat, down, and a buried base under it.
static func outline(angle: float, max_height: float, max_length: float, plateau: float,
		bury: float) -> PackedVector2Array:
	var shape: Vector2 = profile(angle, max_height, max_length, plateau)
	var top: float = plateau * 0.5
	var half: float = shape.y + top
	return PackedVector2Array([
		Vector2(-half, -bury), Vector2(-half, 0.0), Vector2(-top, shape.x),
		Vector2(top, shape.x), Vector2(half, 0.0), Vector2(half, -bury),
	])


## The sign's words: the grade in degrees and as a road sign gives it, in percent.
static func grade_text(angle: float) -> String:
	return "%d°\n%d %%" % [roundi(angle), roundi(tan(deg_to_rad(angle)) * 100.0)]


func _rebuild_deferred() -> void:
	if not is_inside_tree() or _rebuild_queued:
		return
	_rebuild_queued = true
	_rebuild.call_deferred()


func _rebuild() -> void:
	_rebuild_queued = false
	for child in get_children():
		if child.has_meta(GENERATED):
			remove_child(child)
			child.queue_free()
	var points: PackedVector2Array = outline(angle_deg, max_height_m, max_length_m, plateau_m, bury_m)
	var road := CSGPolygon3D.new()
	road.set_meta(GENERATED, true)
	road.name = "Road"
	road.polygon = points
	road.depth = width_m
	road.position.z = width_m * 0.5  # the polygon extrudes towards -Z: centre it on the origin
	road.use_collision = true
	road.material = _material(Color(0.52, 0.52, 0.5))
	add_child(road)
	var foot: float = points[points.size() - 1].x
	_add_sign(-1.0, foot)
	_add_sign(1.0, foot)


## A sign beside the foot on [param side] (-1 or +1 along X), facing the vehicles that drive up from there.
func _add_sign(side: float, foot: float) -> void:
	var sign_node := Node3D.new()
	sign_node.set_meta(GENERATED, true)
	sign_node.name = "SignMinus" if side < 0.0 else "SignPlus"
	sign_node.position = Vector3(side * (foot + 1.5), 0.0, width_m * 0.5 + 1.0)
	sign_node.rotation.y = side * PI * 0.5  # local +Z (the face) towards the approach
	add_child(sign_node)
	var post := MeshInstance3D.new()
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.12, 2.4, 0.12)
	post.mesh = post_mesh
	post.position.y = 1.2
	post.material_override = _material(Color(0.3, 0.3, 0.3))
	sign_node.add_child(post)
	var board := MeshInstance3D.new()
	var board_mesh := BoxMesh.new()
	board_mesh.size = Vector3(1.6, 1.2, 0.06)
	board.mesh = board_mesh
	board.position = Vector3(0.0, 2.4, 0.08)
	board.material_override = _material(Color(0.95, 0.8, 0.1))
	sign_node.add_child(board)
	var label := Label3D.new()
	label.text = grade_text(angle_deg)
	label.font_size = 96
	label.pixel_size = 0.005
	label.modulate = Color.BLACK
	label.outline_size = 0
	label.double_sided = false
	label.position = Vector3(0.0, 2.4, 0.12)
	sign_node.add_child(label)


func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	return mat
