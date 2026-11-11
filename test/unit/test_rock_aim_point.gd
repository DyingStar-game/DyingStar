extends GutTest

## A prompt about a rock piece points at the middle of its surface, not of its box: a wedge fills a
## corner of its box, whose middle is in the air beside it (playtest 2026-11-10).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_rock_aim_point.gd


## A right-angled wedge: the triangle (0,0) (1,0) (0,1) in x, y, 0.2 thick in z.
func _wedge() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := Vector3(0, 0, 0)
	var b := Vector3(1, 0, 0)
	var c := Vector3(0, 1, 0)
	var up := Vector3(0, 0, 0.2)
	for v: Vector3 in [a, b, c, a + up, c + up, b + up,  # the two triangles
			a, a + up, b, b, a + up, b + up,  # the three sides
			b, b + up, c, c, b + up, c + up,
			c, c + up, a, a, c + up, a + up]:
		st.add_vertex(v)
	return st.commit()


func test_a_wedge_is_pointed_at_on_itself_not_at_its_box_s_middle() -> void:
	var mesh := _wedge()
	var box_middle: Vector3 = mesh.get_aabb().get_center()
	assert_almost_eq(box_middle.x + box_middle.y, 1.0, 1e-5, "the box's middle: on the slanted face, off for a thinner piece")
	var centre: Vector3 = RockMining.surface_centre(mesh, box_middle)
	assert_lt(centre.x + centre.y, 0.85, "well inside the wedge")
	assert_gt(centre.x, 0.1)
	assert_gt(centre.y, 0.1)
	assert_almost_eq(centre.z, 0.1, 1e-5, "half its thickness")


func test_without_a_mesh_the_fallback_is_kept() -> void:
	assert_eq(RockMining.surface_centre(null, Vector3(1, 2, 3)), Vector3(1, 2, 3))
	assert_eq(RockMining.surface_centre(ArrayMesh.new(), Vector3(1, 2, 3)), Vector3(1, 2, 3))


func test_a_carved_piece_is_aimed_at_by_its_own_shape() -> void:
	# The look meets the rock's area: a sphere round the whole rock, until a cut gives the piece's hull.
	var rock: RockMining = (load("res://scenes/_universe/environment/terrain/rocks/rock_mining_sm.tscn") as PackedScene).instantiate()
	rock.freeze = true
	add_child_autofree(rock)
	await get_tree().process_frame
	var area_shape := rock.get_node("Area3D/CollisionShape3D") as CollisionShape3D
	assert_true(area_shape.shape is SphereShape3D, "uncut: the cheap sphere")
	rock.fractures = [{"fractured": true, "rotation_x": 0.0, "rotation_y": 30.0, "rotation_z": 0.0,
			"plane_offset": 0.1, "keep_side": 1}]
	rock._ensure_csg_backend(true)
	rock._mesh_node().add_child(rock._make_cut_box(rock.fractures[0]))
	for i in 3:
		await get_tree().process_frame
	rock._build_mesh_collider()
	var body_shape := rock.get_node("CollisionShape3D") as CollisionShape3D
	assert_true(area_shape.shape is ConvexPolygonShape3D, "carved: the piece's hull")
	assert_eq(area_shape.shape, body_shape.shape, "the body's own, shared")
	assert_eq(area_shape.transform, body_shape.transform)
