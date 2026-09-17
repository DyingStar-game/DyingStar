extends GutTest
## [Vehicle.nav_footprint_aabb] — the footprint a PARKED vehicle carves out of the NPC navmesh.
##
## A truck's collision is a compound of convex pieces authored in the GLB (col_cab, col_bed_floor…)
## or, for a blockout, parametric boxes — each placed by its own CollisionShape3D transform. The
## obstacle registered with NpcNavCache is the merged local AABB of those pieces, so the test builds
## one box and one convex hull at two offsets and expects the union, and checks that a shape-less
## node contributes nothing.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_vehicle_nav_footprint.gd


func _shape_node(shape: Shape3D, at: Vector3) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = at
	return cs


func test_union_of_a_box_and_a_convex_piece_at_their_offsets() -> void:
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 1.0, 4.0)  # ±1, ±0.5, ±2 around its node
	var hull := ConvexPolygonShape3D.new()
	hull.points = PackedVector3Array([
		Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(1, 0, 1), Vector3(-1, 0, 1), Vector3(0, 2, 0)])
	var cab := _shape_node(box, Vector3(0.0, 1.0, 3.0))        # x -1..1, y 0.5..1.5, z 1..5
	var bed := _shape_node(hull, Vector3(0.5, 0.0, -2.0))      # x -0.5..1.5, y 0..2, z -3..-1
	var empty := CollisionShape3D.new()
	var stranger := Node3D.new()
	var bb: AABB = Vehicle.nav_footprint_aabb([cab, bed, empty, stranger])
	assert_almost_eq(bb.position, Vector3(-1.0, 0.0, -3.0), Vector3.ONE * 0.001)
	assert_almost_eq(bb.end, Vector3(1.5, 2.0, 5.0), Vector3.ONE * 0.001)
	cab.free()
	bed.free()
	empty.free()
	stranger.free()


func test_no_shapes_means_no_volume() -> void:
	assert_false(Vehicle.nav_footprint_aabb([]).has_volume())
	var empty := CollisionShape3D.new()
	assert_false(Vehicle.nav_footprint_aabb([empty]).has_volume())
	empty.free()
