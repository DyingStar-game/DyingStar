@tool
class_name LayoutLine
extends Path3D
## A line drawn in a village or city layout scene: a Path3D whose curve the level designer draws in
## the 3-D view, straight or curved. The base of the layout's drawn features — a road (VillageRoad), a
## fence (VillageFence) — which the server and every client read from the layout file (LayoutRoads,
## LayoutFences) and lay on the village's ground: nothing of it travels, and a village never spawns
## it (no PropSync).
##
## Only the curve's X and Z count: the feature follows the ground, whatever height its points are at.
##
## Snapping, in the editor: an END of the curve dropped within SNAP_M of an anchor (see
## [method _anchors] — RoadSnaps, the other lines of the same kind) lands exactly on it.

## How close an end must come to an anchor to be pulled onto it (m).
const SNAP_M := 6.0
## Spacing of the points handed to the game (m).
const STEP_M := 4.0

var _snapping := false


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	if curve == null:
		curve = Curve3D.new()
	if not curve.changed.is_connected(_on_curve_changed):
		curve.changed.connect(_on_curve_changed)
	_line_changed()


## The line in [param root]'s frame, as (x, z) every [param step_m] exactly along it (the last stretch
## shorter), both ends included. Works outside the tree.
func polyline_in(root: Node, step_m: float = STEP_M) -> PackedVector2Array:
	var out := PackedVector2Array()
	if curve == null or curve.point_count < 2:
		return out
	var xf := _to(self, root)
	var dense := PackedVector2Array()
	for p: Vector3 in curve.tessellate_even_length(5, minf(step_m * 0.25, 0.5)):
		var q := xf * p
		dense.append(Vector2(q.x, q.z))
	return resample(dense, step_m)


## [param line] resampled every [param step_m] along it, its first and last points kept.
static func resample(line: PackedVector2Array, step_m: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if line.size() < 2:
		return line
	out.append(line[0])
	var next_at := step_m
	var along := 0.0
	for k in line.size() - 1:
		var seg := line[k].distance_to(line[k + 1])
		while seg > 0.0 and along + seg >= next_at:
			out.append(line[k].lerp(line[k + 1], (next_at - along) / seg))
			next_at += step_m
		along += seg
	if out[out.size() - 1].distance_to(line[line.size() - 1]) > step_m * 0.1:
		out.append(line[line.size() - 1])
	else:
		out[out.size() - 1] = line[line.size() - 1]
	return out


## Pull each end of the curve onto the nearest anchor within SNAP_M of it in [param root]. Returns
## how many ends moved.
func snap_ends(root: Node) -> int:
	if root == null or curve == null or curve.point_count < 2:
		return 0
	var to_root := _to(self, root)
	var moved := 0
	for i: int in [0, curve.point_count - 1]:
		var at := to_root * curve.get_point_position(i)
		var best := Vector3.INF
		var best_d := SNAP_M
		for a: Vector3 in _anchors(root, at):
			var d := Vector2(a.x - at.x, a.z - at.z).length()
			if d < best_d:
				best_d = d
				best = a
		if best != Vector3.INF and best_d > 0.001:
			curve.set_point_position(i, to_root.affine_inverse() * Vector3(best.x, at.y, best.z))
			moved += 1
	return moved


## The points an end at [param at] may snap to, in [param root]'s frame: by default the point of each
## other line of the same class nearest to [param at] (anywhere along it, not only at its ends).
func _anchors(root: Node, at: Vector3) -> Array[Vector3]:
	return nearest_on_lines(root, at, get_script())


## The point nearest [param at] on every other line of [param root] whose script is [param script].
func nearest_on_lines(root: Node, at: Vector3, script: Script) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for n: Node in root.find_children("*", "LayoutLine", true, false):
		var other := n as LayoutLine
		if other == self or other.get_script() != script or other.curve == null or other.curve.point_count < 2:
			continue
		var xf := _to(other, root)
		out.append(xf * other.curve.get_closest_point(xf.affine_inverse() * at))
	return out


func _on_curve_changed() -> void:
	if _snapping or not is_inside_tree():
		return
	_snapping = true
	snap_ends(get_tree().edited_scene_root)
	_snapping = false
	_line_changed()


## Called in the editor once the curve has changed and its ends are snapped: a subclass draws its
## preview here.
func _line_changed() -> void:
	pass


## [param node]'s transform in [param root]'s frame, read from the parents' own transforms.
static func _to(node: Node, root: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n := node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf
