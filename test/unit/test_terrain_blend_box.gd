extends GutTest
## The box the ground fringe tells an outer wall from an inner one against (TerrainBlend.box_owner_of,
## terrain_blend.gdshader's blend_box_x): a home of a row of containers is judged against ITS container, not
## against the whole building. Against the building's box, the walls two homes share and the back walls of a
## two-row building looked outward and wore the band of ground INSIDE the homes (2026-11-28).
##
## godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_terrain_blend_box.gd

const APARTMENT := "res://scenes/_universe/structures/buildings/container_apartment.tscn"
## A habitat container (SpawnBuilding's x_spacing, y_spacing, z_spacing) and the thickness of its walls (m).
const LENGTH := 6.1
const HEIGHT := 2.6
const WIDTH := 2.6
const SKIN := 0.06
const COLS := 5


## The shader's own arithmetic (terrain_blend.gdshader vertex(), "With the object's box"), for a mesh whose
## model space is the box's frame: >0 a face looking out of the nearest side of [param box], <0 into it.
func _face_out(vertex: Vector3, normal: Vector3, box: AABB) -> float:
	var box_x: Vector4 = TerrainBlend.box_axis(Basis.IDENTITY, Vector3.RIGHT, box.size.x * 0.5)
	var box_z: Vector4 = TerrainBlend.box_axis(Basis.IDENTITY, Vector3.BACK, box.size.z * 0.5)
	var axis_x := Vector3(box_x.x, box_x.y, box_x.z)
	var axis_z := Vector3(box_z.x, box_z.y, box_z.z)
	var from_c: Vector3 = vertex - box.get_center()
	var px: float = from_c.dot(axis_x)
	var pz: float = from_c.dot(axis_z)
	var side: Vector3 = axis_x * signf(px) if box_x.w - absf(px) < box_z.w - absf(pz) else axis_z * signf(pz)
	return normal.dot(side)


## The cell of the home [param col] of the first row ([param row] 0) or the second, in the building's frame:
## from the facade (x = 0) towards -x, side by side along +z (SpawnBuilding._create_apartments).
func _cell(row: int, col: int) -> AABB:
	return AABB(Vector3(-LENGTH * float(row + 1), 0.0, WIDTH * float(col)), Vector3(LENGTH, HEIGHT, WIDTH))


func _building(rows: int) -> AABB:
	return AABB(Vector3(-LENGTH * float(rows), 0.0, 0.0), Vector3(LENGTH * float(rows), HEIGHT, WIDTH * float(COLS)))


func test_a_wall_shared_with_a_neighbour_is_an_inner_wall_of_its_own_container() -> void:
	var home: AABB = _cell(0, 2)
	for x: float in [-5.5, -3.05, -0.5]:
		# The two long walls as seen from inside the home: each looks at the other.
		var near := Vector3(x, 0.2, home.position.z + SKIN)
		var far := Vector3(x, 0.2, home.end.z - SKIN)
		assert_almost_eq(_face_out(near, Vector3.BACK, home), -1.0, 1e-6, "x %.2f: into its container" % x)
		assert_almost_eq(_face_out(far, Vector3.FORWARD, home), -1.0, 1e-6, "x %.2f: into its container" % x)
		# What the whole building's box said of them: neither in nor out, two thirds of the band.
		assert_almost_eq(_face_out(near, Vector3.BACK, _building(1)), 0.0, 1e-6, "the building's box cannot tell")
		assert_almost_eq(_face_out(far, Vector3.FORWARD, _building(1)), 0.0, 1e-6, "the building's box cannot tell")


func test_the_back_wall_of_a_two_row_building_is_an_inner_wall_of_its_own_container() -> void:
	var home: AABB = _cell(0, 2)
	var inside := Vector3(home.position.x + SKIN, 0.2, home.get_center().z)
	assert_almost_eq(_face_out(inside, Vector3.RIGHT, home), -1.0, 1e-6, "into its container")
	assert_almost_eq(_face_out(inside, Vector3.RIGHT, _building(2)), 1.0, 1e-6,
			"against the two rows' box it looked out of the building: the whole band inside the home")


func test_the_outer_faces_of_a_container_keep_looking_out() -> void:
	var home: AABB = _cell(0, 0)
	var mid: Vector3 = home.get_center()
	assert_almost_eq(_face_out(Vector3(home.end.x, 0.2, mid.z), Vector3.RIGHT, home), 1.0, 1e-6, "the facade")
	assert_almost_eq(_face_out(Vector3(home.position.x, 0.2, mid.z), Vector3.LEFT, home), 1.0, 1e-6, "the back")
	assert_almost_eq(_face_out(Vector3(mid.x, 0.2, home.position.z), Vector3.FORWARD, home), 1.0, 1e-6, "a side")
	assert_almost_eq(_face_out(Vector3(mid.x, 0.2, home.end.z), Vector3.BACK, home), 1.0, 1e-6, "the other side")
	# And the inside of the facade, beside the door, looks in.
	assert_almost_eq(_face_out(Vector3(home.end.x - SKIN, 0.2, mid.z + 0.9), Vector3.LEFT, home), -1.0, 1e-6)


func test_the_box_owner_is_the_nearest_part_in_the_group_else_the_root() -> void:
	var above: Node3D = autofree(Node3D.new())
	above.add_to_group(TerrainBlend.BOX_GROUP)
	var root := Node3D.new()
	above.add_child(root)
	var rooms := Node3D.new()
	root.add_child(rooms)
	var home := Node3D.new()
	home.add_to_group(TerrainBlend.BOX_GROUP)
	rooms.add_child(home)
	var model := Node3D.new()
	home.add_child(model)
	var wall := MeshInstance3D.new()
	model.add_child(wall)
	var pad := MeshInstance3D.new()
	root.add_child(pad)
	assert_eq(TerrainBlend.box_owner_of(wall, root), home, "a home's wall: its home")
	assert_eq(TerrainBlend.box_owner_of(home, root), home, "the part itself")
	assert_eq(TerrainBlend.box_owner_of(pad, root), root, "outside any part: the object's root")
	assert_eq(TerrainBlend.box_owner_of(rooms, root), root, "never above the object's root")
	var inner := Node3D.new()
	inner.add_to_group(TerrainBlend.BOX_GROUP)
	model.add_child(inner)
	var deep := MeshInstance3D.new()
	inner.add_child(deep)
	assert_eq(TerrainBlend.box_owner_of(deep, root), inner, "the nearest part wins")


func test_each_part_gets_the_box_of_its_own_meshes() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var blend := TerrainBlend.new()
	root.add_child(blend)
	var holders: Array[Node3D] = []
	for col in 2:
		var home := Node3D.new()
		home.add_to_group(TerrainBlend.BOX_GROUP)
		home.position = Vector3(0.0, 0.0, WIDTH * float(col))
		root.add_child(home)
		var shell := BoxMesh.new()
		shell.size = Vector3(LENGTH, HEIGHT, WIDTH)
		var mesh := MeshInstance3D.new()
		mesh.mesh = shell
		mesh.position = Vector3(-LENGTH * 0.5, HEIGHT * 0.5, WIDTH * 0.5)
		home.add_child(mesh)
		blend._targets.append(mesh)
		holders.append(TerrainBlend.box_owner_of(mesh, root))
	var boxes: Dictionary = blend._boxes(holders)
	assert_eq(boxes.size(), 2, "one box a home")
	for home: Node3D in holders:
		var box: AABB = boxes[home]
		assert_almost_eq(box.position, Vector3(-LENGTH, 0.0, 0.0), Vector3.ONE * 1e-4, "in the home's own frame")
		assert_almost_eq(box.size, Vector3(LENGTH, HEIGHT, WIDTH), Vector3.ONE * 1e-4, "one container, not the row")


func test_every_home_of_a_building_is_a_box_of_its_own() -> void:
	var apartment: Node3D = (load(APARTMENT) as PackedScene).instantiate()
	assert_true(apartment.is_in_group(TerrainBlend.BOX_GROUP), "the container's root is in the group")
	apartment.free()
	# The other homes are copies of the first: they must keep its groups.
	assert_ne(SpawnBuilding.COPY_AS_IS & Node.DUPLICATE_GROUPS, 0, "a copied home keeps the group")
