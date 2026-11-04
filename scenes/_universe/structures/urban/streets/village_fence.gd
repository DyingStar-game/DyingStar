@tool
class_name VillageFence
extends LayoutLine
## A fence or a palisade drawn in a village or city layout: add a VillageFence to the layout, draw its
## curve in the 3-D view (straight or curved), and the server and every client build it on the
## village's ground — panels between posts, a post every [member post_spacing_m], a collision box per
## panel — from the layout file (LayoutFences). Nothing is stored nor replicated: redrawing a fence
## needs no purge.
##
## Where a road drawn in the layout (VillageRoad) crosses it, the fence opens by itself on the road's
## width and kerb. Its ends snap (LayoutLine) onto any point of another VillageFence: a fence closes
## on its neighbour without a gap.
##
## In the editor the fence is previewed on flat ground (a child never saved with the scene), its gaps
## included; in the game it follows the village's ground.

## Height of the fence above the ground (m).
@export_range(0.5, 6.0, 0.1, "suffix:m") var height_m: float = 2.2:
	set(v):
		height_m = v
		_line_changed()
## Distance between two posts (m); a curve is followed post to post.
@export_range(1.0, 10.0, 0.5, "suffix:m") var post_spacing_m: float = 3.0:
	set(v):
		post_spacing_m = v
		_line_changed()
## The panels' material: the wire mesh of the cargo depot by default, mapped on the panel's own UVs
## (the depot's copy is triplanar, which on a fence drew the mesh diagonally).
@export var panel_material: Material = preload("res://assets/_universe/_shared/materials/urban_wire_fence_panel.tres"):
	set(v):
		panel_material = v
		_line_changed()
## The posts' material.
@export var post_material: Material = preload("res://assets/_universe/_shared/materials/iron_001.tres"):
	set(v):
		post_material = v
		_line_changed()

const PREVIEW_NAME := "_FencePreview"


## Panel k of the fence, from post k to post k + 1 of [param posts] (layout (x, z)), is open where
## a road of [param roads] (LayoutRoads.of_layout) runs under its middle — the editor's version of the
## gap the game opens (VillageRoadBed.distance_out_m), on the same width and kerb.
static func open_panels(posts: PackedVector2Array, roads: Array) -> Array:
	var open: Array = []
	for k in posts.size() - 1:
		var mid := (posts[k] + posts[k + 1]) * 0.5
		var gap := false
		for r: Dictionary in roads:
			if LayoutRoads._dist_to_line(mid, r["points"]) <= float(r["width"]) * 0.5 + VillageRoadBed.EDGE_M:
				gap = true
				break
		open.append(gap)
	return open


## Draw the preview again: flat ground, the curve's own frame, the layout's roads for the gaps.
func _line_changed() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	var old := get_node_or_null(PREVIEW_NAME)
	if old != null:
		old.free()
	var root := get_tree().edited_scene_root
	if root == null or curve == null or curve.point_count < 2:
		return
	var posts := polyline_in(root, post_spacing_m)
	var own := polyline_in(self, post_spacing_m)
	var feet := PackedVector3Array()
	var ups := PackedVector3Array()
	for p: Vector2 in own:
		feet.append(Vector3(p.x, 0.0, p.y))
		ups.append(Vector3.UP)
	var geo := LayoutFences.build(feet, ups, open_panels(posts, LayoutRoads.of_layout(root)), height_m)
	var mesh := ArrayMesh.new()
	if not (geo["panels"] as Array).is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, geo["panels"])
		mesh.surface_set_material(mesh.get_surface_count() - 1, LayoutFences.on_panel_uv(panel_material))
	if not (geo["posts"] as Array).is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, geo["posts"])
		mesh.surface_set_material(mesh.get_surface_count() - 1, post_material)
	var mi := MeshInstance3D.new()
	mi.name = PREVIEW_NAME
	mi.mesh = mesh
	add_child(mi)  # no owner: never saved with the scene
