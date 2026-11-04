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

## Name of the preview child, found again and replaced on every redraw.
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
			if LayoutRoads.distance_to_line(mid, r["points"]) <= float(r["width"]) * 0.5 + VillageRoadBed.EDGE_M:
				gap = true
				break
		open.append(gap)
	return open


## The fence changed: draw its preview again, its gaps read from the layout's roads.
func _line_changed() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	var root := get_tree().edited_scene_root
	if root != null:
		draw_preview(root, LayoutRoads.of_layout(root))


## Draw this fence's preview from [param roads] (LayoutRoads.of_layout of [param root]): flat ground
## (y = 0 of [param root]), in this node's frame, a gap where a road crosses. Called by VillageRoad too,
## so the gaps follow the roads. Works outside the tree.
func draw_preview(root: Node, roads: Array) -> void:
	var old := get_node_or_null(PREVIEW_NAME)
	if old != null:
		old.free()
	var geo := preview_geometry(root, roads)
	if geo.is_empty():
		return
	var mi := MeshInstance3D.new()
	mi.name = PREVIEW_NAME
	mi.mesh = LayoutFences.mesh_of(geo, LayoutFences.on_panel_uv(panel_material), post_material)
	add_child(mi)  # no owner: never saved with the scene


## The preview's geometry (LayoutFences.build), in this node's frame: the posts are resampled ONCE,
## in [param root]'s frame as the game reads them, then moved into this node's frame, so the gaps
## (computed on the same posts) fall on the right panels under a scaled or tilted parent. {} under two
## points.
func preview_geometry(root: Node, roads: Array) -> Dictionary:
	var posts := polyline_in(root, post_spacing_m)
	if posts.size() < 2:
		return {}
	var to_self := frame_in(self, root).affine_inverse()
	var up := (to_self.basis * Vector3.UP).normalized()
	var feet := PackedVector3Array()
	var ups := PackedVector3Array()
	for p: Vector2 in posts:
		feet.append(to_self * Vector3(p.x, 0.0, p.y))
		ups.append(up)
	return LayoutFences.build(feet, ups, open_panels(posts, roads), height_m)
