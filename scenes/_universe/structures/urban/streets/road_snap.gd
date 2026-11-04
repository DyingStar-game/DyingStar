@tool
class_name RoadSnap
extends Marker3D
## Where a road of the planet's network may join a village or a city: drop one in a layout scene
## (ares_village_mining.tscn…) at the edge of the village, its −Z pointing out of the village along
## the way the road leaves. The QGIS road export (tools/planettech/qgis/export/planet/village_snaps.py)
## cuts every road out of the layout's footprint (LayoutFootprint) and runs each cut end to the
## nearest snap of its kind instead, so roads arrive where the level design wants them.
##
## Authoring data only: no PropSync, so a village never spawns it, and nothing of it reaches a client.
## In the editor it shows an arrow in the colour of its kind.

enum Kind { ROAD, PATH, HIGHWAY, RAILWAY }

## The kind of way that may join here (a QGIS road_type: road, path or trail, highway, railway).
@export var kind: Kind = Kind.ROAD:
	set(value):
		kind = value
		_draw_arrow()

## Arrow colour per kind, in the editor.
const COLOURS := {
	Kind.ROAD: Color(1.0, 0.8, 0.0),
	Kind.PATH: Color(0.55, 0.85, 0.35),
	Kind.HIGHWAY: Color(1.0, 0.35, 0.1),
	Kind.RAILWAY: Color(0.6, 0.6, 0.7),
}
## The name the road export reads (QGIS road_type family).
const KIND_NAMES := {Kind.ROAD: "road", Kind.PATH: "path", Kind.HIGHWAY: "highway", Kind.RAILWAY: "railway"}
## Length of the editor's arrow along −Z (m): long enough to read the snap's direction from afar.
const ARROW_M := 8.0

var _arrow: MeshInstance3D = null


func _ready() -> void:
	_draw_arrow()


## The way this snap's [member kind] is called in the exported JSON ("road", "path"…).
func kind_name() -> String:
	return str(KIND_NAMES[kind])


## Editor only: (re)draw the arrow in the colour of [member kind], an internal child never saved with
## the layout. Called again whenever the kind changes.
func _draw_arrow() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if _arrow == null:
		_arrow = MeshInstance3D.new()
		add_child(_arrow, false, Node.INTERNAL_MODE_FRONT)  # never saved into the layout
	var mesh := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = COLOURS[kind]
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	var tip := Vector3(0.0, 0.5, -ARROW_M)
	for v: Vector3 in [Vector3(0.0, 0.5, 0.0), tip, tip, tip + Vector3(-1.5, 0.0, 2.0), tip,
			tip + Vector3(1.5, 0.0, 2.0)]:
		mesh.surface_add_vertex(v)
	mesh.surface_end()
	_arrow.mesh = mesh
