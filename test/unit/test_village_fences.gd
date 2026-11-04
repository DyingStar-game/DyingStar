extends GutTest
## VillageFence: drawn in a layout, built on the ground by PlanetTerrain from LayoutFences — panels
## between posts, a post where a panel stands, a gap where a road crosses, collision on the panels.


func test_a_fence_is_read_from_its_layout_post_by_post() -> void:
	var root := Node3D.new()
	var fence := VillageFence.new()
	fence.post_spacing_m = 3.0
	fence.curve = Curve3D.new()
	fence.curve.add_point(Vector3(0.0, 0.0, 0.0))
	fence.curve.add_point(Vector3(30.0, 0.0, 0.0))
	root.add_child(fence)
	var fences := LayoutFences.of_layout(root)
	assert_eq(fences.size(), 1)
	var pts: PackedVector2Array = fences[0]["points"]
	assert_between(pts.size(), 10, 12, "about one post every 3 m over 30 m")
	assert_eq(float(fences[0]["height"]), fence.height_m)
	assert_not_null(fences[0]["panel_material"], "the wire mesh by default")
	root.free()


func test_a_road_opens_a_gap() -> void:
	var feet := PackedVector3Array([Vector3(0, 0, 0), Vector3(3, 0, 0), Vector3(6, 0, 0), Vector3(9, 0, 0)])
	var ups := PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	var geo := LayoutFences.build(feet, ups, [false, true, false], 2.0)
	var panels: Array = geo["panels"]
	assert_eq((panels[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), 8, "two panels, the middle one open")
	assert_eq((geo["boxes"] as Array).size(), 2, "a collision box for each panel only")
	var box: Array = (geo["boxes"] as Array)[0]
	assert_almost_eq((box[1] as Vector3).x, 3.0, 0.001, "as long as its panel")
	assert_almost_eq((box[0] as Transform3D).origin, Vector3(1.5, 1.0, 0.0), Vector3.ONE * 0.001, "and on it")
	assert_eq((panels[Mesh.ARRAY_TANGENT] as PackedFloat32Array).size(), 8 * 4, "tangents for the wire mesh")
	var posts: Array = geo["posts"]
	assert_eq((posts[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), 4 * 4 * 4, "a post at each end of each panel")
	var top := (panels[Mesh.ARRAY_VERTEX] as PackedVector3Array)[2]
	assert_almost_eq(top.y, 2.0, 0.001, "as high as asked, along the local up")


func test_a_fence_all_open_draws_nothing() -> void:
	var feet := PackedVector3Array([Vector3(0, 0, 0), Vector3(3, 0, 0)])
	var geo := LayoutFences.build(feet, PackedVector3Array([Vector3.UP, Vector3.UP]), [true], 2.0)
	assert_eq(geo["panels"], [], "no panel")
	assert_eq(geo["posts"], [], "no post")


## On a slope the texture hangs plumb: the same V at the same height on both posts of a panel, so
## the wire mesh's bars stay level while the panel follows the ground.
func test_on_a_slope_the_texture_stays_level() -> void:
	var feet := PackedVector3Array([Vector3(0, 0, 0), Vector3(3, 1, 0)])  # one metre up over three
	var ups := PackedVector3Array([Vector3.UP, Vector3.UP])
	var geo := LayoutFences.build(feet, ups, [false], 2.0)
	var v: PackedVector3Array = (geo["panels"] as Array)[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = (geo["panels"] as Array)[Mesh.ARRAY_TEX_UV]
	# vertex 1 (foot of the second post, y = 1) and vertex 3 (top of the first post, y = 2)
	assert_almost_eq(uv[1].y, -1.0 / LayoutFences.TILE_M, 0.001, "V follows the height, not the edge")
	assert_almost_eq(uv[3].y, -2.0 / LayoutFences.TILE_M, 0.001)
	assert_almost_eq(uv[1].x, 3.0 / LayoutFences.TILE_M, 0.001, "U follows the horizontal distance")
	assert_almost_eq(v[2].y, 3.0, 0.001, "the panel itself still follows the ground")


## The cargo depot's triplanar wire mesh, picked for a fence, is drawn from a copy mapped on the
## panels' UVs: triplanar projects along the planet's axes and drew the mesh diagonally.
func test_a_triplanar_material_is_mapped_on_the_panels() -> void:
	var depot: BaseMaterial3D = load("res://assets/_universe/_shared/materials/urban_wire_fence.tres")
	assert_true(depot.uv1_triplanar, "the depot's material is triplanar")
	var on_panels := LayoutFences.on_panel_uv(depot) as BaseMaterial3D
	assert_false(on_panels.uv1_triplanar, "the fence's copy is not")
	assert_eq(on_panels.albedo_texture, depot.albedo_texture, "same wire mesh")
	assert_true(depot.uv1_triplanar, "the depot keeps its own")
	assert_eq(LayoutFences.on_panel_uv(depot), on_panels, "one copy per material")
	var plain := StandardMaterial3D.new()
	assert_eq(LayoutFences.on_panel_uv(plain), plain, "a UV-mapped material is used as it is")


func _fence(points: Array) -> VillageFence:
	var fence := VillageFence.new()
	fence.curve = Curve3D.new()
	for p: Vector3 in points:
		fence.curve.add_point(p)
	return fence


## Under a scaled parent the posts are resampled once, in the layout's frame: as many panels as the
## game builds, each one where the game puts it. Resampled in the fence's own frame too, half as many
## feet came back for the gap flags of the layout's posts.
func test_the_preview_stands_on_the_layout_s_posts() -> void:
	var root := Node3D.new()
	var parent := Node3D.new()
	parent.scale = Vector3(2.0, 1.0, 2.0)
	parent.position = Vector3(5.0, 0.0, 7.0)
	root.add_child(parent)
	var fence := _fence([Vector3(0.0, 0.0, 0.0), Vector3(15.0, 0.0, 0.0)])  # 30 m in the layout
	parent.add_child(fence)
	var posts := fence.polyline_in(root, fence.post_spacing_m)
	var boxes: Array = fence.preview_geometry(root, [])["boxes"]
	assert_eq(boxes.size(), posts.size() - 1, "one panel between two of the layout's posts")
	var to_root := LayoutLine.frame_in(fence, root)
	var mid := to_root * (boxes[0][0] as Transform3D).origin
	var want := (posts[0] + posts[1]) * 0.5
	assert_almost_eq(Vector2(mid.x, mid.z), want, Vector2.ONE * 0.001, "the first panel between the first posts")
	root.free()


## A single fence drawn round a yard closes into a ring: its last end snaps onto its first.
func test_a_fence_closes_on_its_own_start() -> void:
	var root := Node3D.new()
	var fence := _fence([Vector3(0.0, 0.0, 0.0), Vector3(30.0, 0.0, 0.0), Vector3(30.0, 0.0, 30.0),
			Vector3(2.0, 0.0, 3.0)])
	root.add_child(fence)
	assert_eq(fence.snap_ends(root), 1, "one end moved onto the other")
	assert_eq(fence.curve.get_point_position(0), fence.curve.get_point_position(3), "a closed ring")
	root.free()


## The line's own interior is no anchor, and a two-point line never folds onto itself.
func test_a_fence_never_snaps_onto_its_own_middle() -> void:
	var root := Node3D.new()
	var hook := _fence([Vector3(0.0, 0.0, 0.0), Vector3(30.0, 0.0, 0.0), Vector3(30.0, 0.0, 30.0),
			Vector3(27.0, 0.0, 3.0)])
	root.add_child(hook)
	assert_eq(hook.snap_ends(root), 0, "3 m from its own corner, 27 m from its start: stays")
	var stub := _fence([Vector3(0.0, 0.0, 0.0), Vector3(4.0, 0.0, 0.0)])
	root.add_child(stub)
	assert_eq(stub.snap_ends(root), 0, "a 4 m fence keeps its two ends apart")
	root.free()
