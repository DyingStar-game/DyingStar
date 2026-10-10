class_name DrawnGround
extends RefCounted
## The ground as the player SEES it: the distance from a planet's centre to the chunk mesh drawn in
## a direction, measured on the mesh itself. A height query gives what a chunk was built from; what
## it shows can differ by a few decimetres (the relief the chunk gated or levelled, the grid's
## interpolation between vertices 25 m apart), and a figure put on the query stands in the ground.
##
## `mesh_at` answers the drawn chunk under a direction (PlanetTerrain.drawn_mesh_at); `fallback` the
## analytic ground while nothing is drawn there yet. Each mesh's triangle tree is built once.

## The ray starts this far above the planet's radius: above any relief of the worlds we have.
const CAST_FROM_M : float = 30000.0

var _frame : Node3D
var _radius : float
var _mesh_at : Callable
var _fallback : Callable
## Mesh instance id -> its TriangleMesh.
var _trees : Dictionary = {}


## [param frame] is the planet node (directions are in its local space), [param mesh_at] takes a
## direction and returns a MeshInstance3D or null, [param fallback] a direction and returns a distance.
func _init(frame: Node3D, radius: float, mesh_at: Callable, fallback: Callable) -> void:
	_frame = frame
	_radius = radius
	_mesh_at = mesh_at
	_fallback = fallback


## Distance from the centre to the drawn surface along [param dir] (a unit direction, planet-local).
func dist(dir: Vector3) -> float:
	var mi : MeshInstance3D = _mesh_at.call(dir)
	if mi != null and mi.mesh != null and mi.is_inside_tree():
		var tree : TriangleMesh = _tree_of(mi)
		var inv : Transform3D = mi.global_transform.affine_inverse()
		var from_l : Vector3 = inv * _frame.to_global(dir * (_radius + CAST_FROM_M))
		var dir_l : Vector3 = (inv.basis * (_frame.global_basis * -dir)).normalized()
		var hit : Dictionary = tree.intersect_ray(from_l, dir_l)
		if not hit.is_empty():
			return _frame.to_local(mi.global_transform * hit["position"]).length()
	return float(_fallback.call(dir))


func _tree_of(mi: MeshInstance3D) -> TriangleMesh:
	var key : int = mi.mesh.get_instance_id()
	if not _trees.has(key):
		_trees[key] = mi.mesh.generate_triangle_mesh()
	return _trees[key]
