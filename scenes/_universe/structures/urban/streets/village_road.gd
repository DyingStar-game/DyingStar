@tool
class_name VillageRoad
extends LayoutLine
## A road or an alley INSIDE a village or a city, drawn in its layout scene: add a VillageRoad to the
## layout (ares_village_mining.tscn…), then draw its curve in the 3-D view like any Path3D. The
## terrain paints it with the same ribbon as a QGIS road (RoadRibbon, through
## PlanetData.get_roads_for_chunk): asphalt or a path laid ON the ground, no slab and no step, and
## since a village stands on one plane (VillageBed) the road follows that plane the whole way.
##
## Its ends snap (LayoutLine) onto a RoadSnap of its kind and onto any point of another VillageRoad:
## the inner roads join the snaps the outer roads arrive at, and each other, without a gap. Where two
## roads overlap, the larger one wins the ground and the other's ribbon stops at its edge (LayoutRoads).
##
## In the editor the ribbon is previewed on flat ground (a child never saved with the scene), cut at
## the junctions exactly as the game cuts it.

enum Kind { ROAD, PATH }

## The QGIS road_type the ribbon is drawn as (its material and texture).
const KIND_NAMES := {Kind.ROAD: "road", Kind.PATH: "path"}
## The preview's material per kind: the terrain's asphalt; a path takes the biome's in the game.
const PREVIEW_MATERIALS := {
	Kind.ROAD: RoadTerrain.ASPHALT_MATERIAL_PATH,
	Kind.PATH: RoadTerrain.MATERIAL_DIR + "path_dirt.tres",
}
const PREVIEW_NAME := "_RoadPreview"
## Height of the preview above the layout's ground (m), over the TerrainPad boxes' tops.
const PREVIEW_LIFT_M := 0.03

## Road (asphalt, for vehicles) or path (pedestrian alley).
@export var kind: Kind = Kind.ROAD:
	set(v):
		kind = v
		_line_changed()
## Total width of the road (m).
@export_range(1.0, 40.0, 0.5, "suffix:m") var width_m: float = 12.0:
	set(v):
		width_m = v
		_line_changed()


## The QGIS road_type of this road.
func kind_name() -> String:
	return KIND_NAMES[kind]


## Every RoadSnap of this road's kind, and the nearest point of every other VillageRoad.
func _anchors(root: Node, at: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for s: Node in root.find_children("*", "RoadSnap", true, false):
		if (s as RoadSnap).kind_name() == kind_name():
			out.append(_to(s, root).origin)
	out.append_array(nearest_on_lines(root, at, get_script()))
	return out


## One road changed: every road of the layout previews again, since a junction cuts its neighbour.
func _line_changed() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	var root := get_tree().edited_scene_root
	if root == null:
		return
	var roads := LayoutRoads.of_layout(root)
	for n: Node in root.find_children("*", "VillageRoad", true, false):
		(n as VillageRoad).draw_preview(root, roads)


## Draw this road's preview from [param roads] (LayoutRoads.of_layout of [param root]): its visible
## stretches as flat ribbons, in this node's frame.
func draw_preview(root: Node, roads: Array) -> void:
	var old := get_node_or_null(PREVIEW_NAME)
	if old != null:
		old.free()
	var me := str(root.get_path_to(self))
	var runs: Array = []
	for r: Dictionary in roads:
		if r["path"] == me:
			runs = r["runs"]
	if runs.is_empty():
		return
	var to_self := _to(self, root).affine_inverse()
	var tile := RoadTerrain.get_tile_size(kind_name())
	var mesh := ArrayMesh.new()
	for run: Array in runs:
		var arrays := strip(run[0], run[1], width_m * 0.5, tile, to_self, PREVIEW_LIFT_M)
		if not arrays.is_empty():
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, load(PREVIEW_MATERIALS[kind]))
	var mi := MeshInstance3D.new()
	mi.name = PREVIEW_NAME
	mi.mesh = mesh
	add_child(mi)  # no owner: never saved with the scene


## A flat ribbon [param half_w] wide each side of [param pts] (layout (x, z)), [param lift] above
## y = 0, stated through [param xform]; U along ([param cum], metres) and V across, one texture per
## [param tile] metres, as the terrain's ribbon is textured. [] under two points.
static func strip(pts: PackedVector2Array, cum: PackedFloat64Array, half_w: float, tile: float,
		xform: Transform3D, lift: float) -> Array:
	if pts.size() < 2:
		return []
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in pts.size():
		var d := (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]).normalized()
		var side := Vector2(-d.y, d.x) * half_w
		var up := xform.basis * Vector3.UP
		v.append(xform * Vector3(pts[i].x + side.x, lift, pts[i].y + side.y))
		v.append(xform * Vector3(pts[i].x - side.x, lift, pts[i].y - side.y))
		n.append(up)
		n.append(up)
		uv.append(Vector2(cum[i] / tile, 0.0))
		uv.append(Vector2(cum[i] / tile, half_w * 2.0 / tile))
		if i > 0:
			var b := (i - 1) * 2
			# Both windings: the preview shows from above whatever the material culls.
			idx.append_array(PackedInt32Array([b, b + 1, b + 2, b + 1, b + 3, b + 2,
					b, b + 2, b + 1, b + 1, b + 2, b + 3]))
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_INDEX] = idx
	return arr
