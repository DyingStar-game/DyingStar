extends GutTest
## VolcanoStoneField makes its rocks from a sphere's arrays made by itself (sphere_arrays), not read back from a
## SphereMesh (a GPU read-back in game): they must be the engine's own sphere, so the rocks are the same.


func _engine(radial: int, rings: int) -> Array:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = radial
	sphere.rings = rings
	return sphere.get_mesh_arrays()


## The largest gap between two arrays of vectors (or of floats), INF when their sizes differ.
func _gap(a: Variant, b: Variant) -> float:
	if a.size() != b.size():
		return INF
	var worst := 0.0
	for k in a.size():
		var d: float = (a[k] - b[k]).length() if a[k] is Vector3 or a[k] is Vector2 else absf(a[k] - b[k])
		worst = maxf(worst, d)
	return worst


func test_the_sphere_is_the_engine_s() -> void:
	for size: Array in [[28, 14], [9, 5]]:
		var mine := VolcanoStoneField.sphere_arrays(size[0], size[1])
		var theirs := _engine(size[0], size[1])
		assert_eq(mine[Mesh.ARRAY_INDEX], theirs[Mesh.ARRAY_INDEX], "the same triangles %s" % str(size))
		assert_lt(_gap(mine[Mesh.ARRAY_VERTEX], theirs[Mesh.ARRAY_VERTEX]), 1e-5, "the same points %s" % str(size))
		assert_lt(_gap(mine[Mesh.ARRAY_TEX_UV], theirs[Mesh.ARRAY_TEX_UV]), 1e-5, "the same UVs %s" % str(size))
		# Normals and tangents come back from the engine packed (octahedral): close, not equal.
		assert_lt(_gap(mine[Mesh.ARRAY_NORMAL], theirs[Mesh.ARRAY_NORMAL]), 1e-2, "the same normals %s" % str(size))
		assert_lt(_gap(mine[Mesh.ARRAY_TANGENT], theirs[Mesh.ARRAY_TANGENT]), 1e-2, "the same tangents %s" % str(size))


func test_a_rock_is_made_without_reading_a_mesh_back() -> void:
	var rock := VolcanoStoneField.make_rock(28, 14, 3)
	assert_eq(rock.get_surface_count(), 1)
	assert_gt((rock.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), 400)
