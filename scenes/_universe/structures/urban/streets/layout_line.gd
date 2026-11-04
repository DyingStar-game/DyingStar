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
## [method _anchors] — RoadSnaps, the other lines of the same kind, the line's own other end) lands
## exactly on it, measured in X and Z only.

## How close an end must come to an anchor to be pulled onto it (m).
const SNAP_M := 6.0
## Spacing of the points handed to the game (m).
const STEP_M := 4.0
## Spacing of the dense polyline the curve is first flattened into (m): fine enough that resampling
## and the nearest-point search follow a curve's bends.
const DENSE_STEP_M := 0.5

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
	return resample(_flat_in(root, minf(step_m * 0.25, DENSE_STEP_M)), step_m)


## The curve tessellated every [param step_m] or less and flattened into [param root]'s (x, z): the
## line as the game sees it, its heights dropped. [] under two points.
func _flat_in(root: Node, step_m: float) -> PackedVector2Array:
	var dense := PackedVector2Array()
	if curve == null or curve.point_count < 2:
		return dense
	var xf := frame_in(self, root)
	for p: Vector3 in curve.tessellate_even_length(5, step_m):
		var q := xf * p
		dense.append(Vector2(q.x, q.z))
	return dense


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
##
## Besides [method _anchors], each end may snap onto the line's OTHER end (never onto its interior), so
## a single line drawn round a yard closes into a ring; a two-point line never does, it would collapse.
func snap_ends(root: Node) -> int:
	if root == null or curve == null or curve.point_count < 2:
		return 0
	var to_root := frame_in(self, root)
	var last := curve.point_count - 1
	var moved := 0
	for i: int in [0, last]:
		var at := to_root * curve.get_point_position(i)
		var best := Vector3.INF
		var best_d := SNAP_M
		var anchors := _anchors(root, at)
		if curve.point_count >= 3:
			anchors.append(to_root * curve.get_point_position(last - i))
		for a: Vector3 in anchors:
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


## The point nearest [param at] on every other line of [param root] whose script is [param script],
## in X and Z only (at [param at]'s height): only those count, and a 3-D search let a line drawn higher
## or lower pull the nearest point away along its slope.
func nearest_on_lines(root: Node, at: Vector3, script: Script) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var here := Vector2(at.x, at.z)
	for n: Node in root.find_children("*", "LayoutLine", true, false):
		var other := n as LayoutLine
		if other == self or other.get_script() != script:
			continue
		var flat := other._flat_in(root, DENSE_STEP_M)
		if flat.size() < 2:
			continue
		var best := flat[0]
		for k in flat.size() - 1:
			var q := Geometry2D.get_closest_point_to_segment(here, flat[k], flat[k + 1])
			if q.distance_squared_to(here) < best.distance_squared_to(here):
				best = q
		out.append(Vector3(best.x, at.y, best.y))
	return out


## Editor only: the designer moved a point. Snap the ends (which changes the curve again, hence the
## guard against re-entering), then let the subclass redraw its preview.
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


## [param node]'s transform in [param root]'s frame, read from the parents' own transforms (not the
## global ones), so it works on a layout instantiated outside the tree. The identity when [param node]
## is [param root]; up to the top of the tree when [param root] is not one of its ancestors.
static func frame_in(node: Node, root: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n := node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf
