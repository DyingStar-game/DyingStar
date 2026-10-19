@tool
class_name MapMarker
extends Node3D

## How an object shows on the star chart (F2): its footprint as a flat rectangle on the ground, in
## [member colour], with [member icon] over it when it has one. Drop one in the scene of anything that
## should be seen on the chart -- a building, a dispenser, a vehicle -- and set the two in the inspector;
## the chart reads every MapMarker of the body it shows (StarMapMarkers) and knows nothing else about
## what it draws. No icon: the rectangle alone.
##
## The marker stands for its PARENT, the object's root: its footprint is the box around the parent's
## visible meshes, measured once (or [member footprint_size] when set). Only what this client knows of
## is drawn: the objects the server replicates to it, near the player.

const GROUP := &"map_marker"

## The pictogram drawn over the rectangle (assets/textures/map_markers/). Empty: no pictogram.
@export var icon: Texture2D
## Its name on the chart, shown when the pointer is over it (a %% key of tools/localization). Empty:
## the scene's own name.
@export var label: String = ""
## How much it matters on the chart: 1 = most (a garage, a lift, a teleporter), then 2 (homes), 3
## (dispensers)... Drawn over the less important; the chart's points of interest are always over all.
@export_range(1, 9) var importance: int = 3
## Hidden once the camera stands higher than this above the ground (m): a dispenser is noise seen from a
## kilometre up, a garage is still a landmark there.
@export_range(10.0, 100000.0, 10.0) var max_view_m: float = 500.0
## Draw its footprint as a rectangle (a building, a dispenser); off: the pictogram alone (a vehicle).
@export var show_footprint: bool = true
## The rectangle's colour on the chart.
@export var colour: Color = Color(0.62, 0.64, 0.68, 0.85)
## The footprint (m, the parent's frame: x across, z along; y its height). Zero: measured from the
## parent's visible meshes.
@export var footprint_size: Vector3 = Vector3.ZERO

var _box := AABB()
var _measured := false


func _ready() -> void:
	add_to_group(GROUP)


## The object this marker stands for.
func subject() -> Node3D:
	return get_parent() as Node3D


## The name to show: [member label] translated, or the scene's own name when none is set.
func display_name() -> String:
	if label != "":
		return TranslationServer.translate(label)
	var parent: Node = subject()
	if parent == null:
		return ""
	var file: String = parent.scene_file_path.get_file().get_basename()
	return (file if file != "" else str(parent.name)).capitalize()


## What the object fills, in its own frame (the parent's): footprint_size around the parent's origin
## when set, else the box around its visible meshes, measured once.
func footprint() -> AABB:
	if footprint_size != Vector3.ZERO:
		return AABB(Vector3(-footprint_size.x * 0.5, 0.0, -footprint_size.z * 0.5), footprint_size)
	if _measured:
		return _box
	var parent: Node3D = subject()
	if parent == null:
		return AABB()
	var first := true
	# Meshes and CSG shapes (a blockout -- the dispensers are -- has no mesh at all), nothing else: a light
	# is a VisualInstance3D too, and a headlight's 150 m reach would be the box.
	for node: Node in parent.find_children("*", "GeometryInstance3D", true, false):
		var shape := node as GeometryInstance3D
		var drawn: bool = (shape is MeshInstance3D and (shape as MeshInstance3D).mesh != null) or shape is CSGShape3D
		if not drawn or not shape.is_visible_in_tree():
			continue
		var box: AABB = LocalFrame.of(shape, parent) * shape.get_aabb()
		_box = box if first else _box.merge(box)
		first = false
	_measured = not first  # nothing drawn yet (still loading): asked again next time
	return _box
