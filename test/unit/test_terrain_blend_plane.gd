## Pins TerrainBlend.plane_for against the arithmetic terrain_blend.gdshader actually performs.
##
## The two live in different languages and nothing connects them: if they disagree, no error is
## raised anywhere. The fringe is simply painted at the wrong height, or -- when the plane comes out
## near zero -- across a whole wall. That is the failure this file exists to catch.
##
## It is also the test that would have caught the first implementation: it used the normalised
## INVERSE basis with a scale factor applied afterwards, which is exact for a uniform scale and
## wrong by 2.5x on one component for diag(1, 2, 1) -- i.e. wrong for any rock stretched for
## variety, on the one axis nobody would think to check.
##
## godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_terrain_blend_plane.gd
extends GutTest

# Deliberately aligned with NO principal axis: that is the case where the transpose and the
# normalised inverse part company. An axis-aligned up would let the wrong formula pass.
const UP := Vector3(1.0, 1.0, 0.0)

# A few probe points, none of them the origin, spread over all octants.
const PROBES: Array[Vector3] = [
	Vector3(0.0, 0.0, 0.0),
	Vector3(1.0, 0.0, 0.0),
	Vector3(0.0, 1.0, 0.0),
	Vector3(0.0, 0.0, 1.0),
	Vector3(2.5, -1.5, 0.75),
	Vector3(-3.0, 4.0, -2.0),
]


## Exactly what terrain_blend.gdshader's vertex() computes, transcribed by hand. Deliberately NOT
## factored out into shared code: a shared helper would hide a disagreement instead of exposing it.
func _shader_height(plane: Vector4, vertex: Vector3) -> float:
	return Vector3(plane.x, plane.y, plane.z).dot(vertex) + plane.w


func _check(xform: Transform3D, up: Vector3, ground: Vector3, what: String) -> void:
	var plane: Vector4 = TerrainBlend.plane_for(xform, up, ground)
	for v: Vector3 in PROBES:
		# The truth: how far above the ground plane this vertex really is, in world metres.
		var expected: float = up.dot(xform * v - ground)
		assert_almost_eq(
				_shader_height(plane, v), expected, 1e-4,
				"%s: vertex %s should sit %.4f m above the ground" % [what, v, expected])


func test_height_is_world_metres_under_a_non_uniform_scale() -> void:
	# The case the first implementation got wrong.
	var basis := Basis.from_euler(Vector3(0.3, 0.7, -0.2)).scaled(Vector3(1.0, 2.0, 1.0))
	# A translation of astronomic size, as on the client where the planet orbits at ~1e11 m: the
	# plane must not care, because w = 0 arithmetic and model space are all it ever uses.
	var xform := Transform3D(basis, Vector3(9.4e10, -4.1e10, 2.2e10))
	_check(xform, UP.normalized(), Vector3(9.4e10 + 3.0, -4.1e10 - 1.0, 2.2e10 + 2.0), "non-uniform scale")


func test_height_is_world_metres_under_a_uniform_scale() -> void:
	# Non-regression on the easy case, where both the right and the wrong formula agree.
	var basis := Basis.from_euler(Vector3(-0.9, 0.2, 1.1)).scaled(Vector3(3.0, 3.0, 3.0))
	_check(Transform3D(basis, Vector3(12.0, 5.0, -7.0)), UP.normalized(), Vector3(1.0, 2.0, 3.0), "uniform scale")


func test_height_is_world_metres_with_no_scale_at_all() -> void:
	_check(Transform3D(Basis.IDENTITY, Vector3.ZERO), Vector3.UP, Vector3.ZERO, "identity")


func test_a_vertex_on_the_ground_reads_zero() -> void:
	var basis := Basis.from_euler(Vector3(0.1, -0.4, 0.8)).scaled(Vector3(2.0, 0.5, 1.5))
	var xform := Transform3D(basis, Vector3(100.0, 200.0, 300.0))
	var ground := Vector3(101.0, 199.0, 302.0)
	var plane: Vector4 = TerrainBlend.plane_for(xform, UP.normalized(), ground)
	# The ground point itself, expressed as a vertex of this mesh, must read exactly zero -- that is
	# what makes the fringe start AT the ground rather than floating above or sinking below it.
	assert_almost_eq(_shader_height(plane, xform.affine_inverse() * ground), 0.0, 1e-4,
			"the ground point must read 0 m above the ground")


func test_the_plane_normal_is_never_degenerate() -> void:
	# The shader discards on a near-zero plane, because an all-zero plane would read as "height 0
	# everywhere" and repaint the entire object in ground colour. A real transform must never
	# produce one, or that guard would start swallowing legitimate fringes.
	var basis := Basis.from_euler(Vector3(0.5, 0.5, 0.5)).scaled(Vector3(0.01, 0.01, 0.01))
	var plane: Vector4 = TerrainBlend.plane_for(Transform3D(basis, Vector3.ZERO), UP.normalized(), Vector3.ZERO)
	var n := Vector3(plane.x, plane.y, plane.z)
	assert_gt(n.length_squared(), 1e-12, "a 1 cm-scaled object must still get a usable plane")
