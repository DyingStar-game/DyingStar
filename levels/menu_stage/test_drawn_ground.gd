extends GutTest
## DrawnGround measures the drawn mesh, not the height query: a prop snapped to it stands on what the
## player sees. Without a mesh under the direction it falls back to the query.

const RADIUS : float = 90.0
const MESH_Y : float = 100.0

var _frame : Node3D
var _mesh : MeshInstance3D


func before_each() -> void:
	_frame = Node3D.new()
	_frame.position = Vector3(5.0, -3.0, 2.0)  # the planet is not at the world origin
	add_child_autofree(_frame)
	_mesh = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(10.0, 10.0)
	_mesh.mesh = plane
	_mesh.position = Vector3(0.0, MESH_Y, 0.0)
	_frame.add_child(_mesh)


func _mesh_under(_dir: Vector3) -> MeshInstance3D:
	return _mesh


func _no_mesh(_dir: Vector3) -> MeshInstance3D:
	return null


func _query(_dir: Vector3) -> float:
	return RADIUS + 1.0


func test_the_drawn_mesh_is_measured_where_it_is() -> void:
	var ground := DrawnGround.new(_frame, RADIUS, _mesh_under, _query)
	assert_almost_eq(ground.dist(Vector3.UP), MESH_Y, 1e-3, "the mesh's surface, not the query's 91")
	_mesh.position.y = MESH_Y + 0.2  # the chunk re-drawn higher: the tree is rebuilt only per mesh, the transform is live
	assert_almost_eq(ground.dist(Vector3.UP), MESH_Y + 0.2, 1e-3)


func test_the_query_answers_while_nothing_is_drawn() -> void:
	var ground := DrawnGround.new(_frame, RADIUS, _no_mesh, _query)
	assert_almost_eq(ground.dist(Vector3.UP), RADIUS + 1.0, 1e-9)
	var beside := DrawnGround.new(_frame, RADIUS, _mesh_under, _query)
	assert_almost_eq(beside.dist(Vector3.RIGHT), RADIUS + 1.0, 1e-9, "the ray misses the quad: the query")
