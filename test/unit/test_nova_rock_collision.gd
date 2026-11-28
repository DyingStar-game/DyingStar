extends GutTest
## The colliders of Nova's scattered rocks: which rocks collide (NovaScatter.is_solid), that the server's
## solid-only laying gives exactly the rocks the client draws as colliding, at the same place, their shapes
## (their model scene's, else its hull, scaled with the rock) and the debug view's wireframes (Settings > Debug).
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_nova_rock_collision.gd

const ROCKS := preload("res://scenes/planet/nova/nova_rock_collision.gd")
const DEBUG_VIEW := preload("res://scenes/planet/nova/nova_scatter_collision_debug.gd")
const RADIUS := 1000000.0
const NSIDE := 8192
const IPIX := 12345
const RES := 4


func test_long_and_proud_rocks_collide() -> void:
	var flat := AABB(Vector3(-2.0, 0.0, -2.0), Vector3(4.0, 0.06, 4.0))
	assert_false(NovaScatter.is_solid(flat, 1.0, 0.05), "a 4 m gravel patch 6 cm thick does not")
	var pebble := AABB(Vector3(-0.4, 0.0, -0.4), Vector3(0.8, 0.8, 0.8))
	assert_false(NovaScatter.is_solid(pebble, 1.0, 0.0), "under a metre long it does not")
	var boulder := AABB(Vector3(-1.0, 0.0, -1.0), Vector3(2.0, 1.0, 2.0))
	assert_true(NovaScatter.is_solid(boulder, 1.0, 0.05), "a 2 m boulder 0.95 m out of the ground does")
	var low := AABB(Vector3(-0.6, 0.0, -0.6), Vector3(1.2, 0.5, 1.2))
	assert_false(NovaScatter.is_solid(low, 1.0, 0.1), "0.45 m above the ground once sunk: not")
	assert_true(NovaScatter.is_solid(low, 1.2, 0.1), "scaled up past the rule: yes")


func test_solid_scale_is_where_the_rule_turns() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 200:
		var aabb := AABB(Vector3(-1.0, rng.randf_range(-0.5, 0.2), -1.0),
				Vector3(rng.randf_range(0.1, 6.0), rng.randf_range(0.02, 3.0), rng.randf_range(0.1, 6.0)))
		var sink := rng.randf_range(0.0, 0.3)
		var s := NovaScatter.solid_scale(aabb, sink)
		if is_inf(s):
			assert_false(NovaScatter.is_solid(aabb, 50.0, sink), "never solid, at any scale")
			continue
		assert_true(NovaScatter.is_solid(aabb, s * 1.0001, sink), "solid just above %.4f" % s)
		assert_false(NovaScatter.is_solid(aabb, s * 0.9999, sink), "not just below %.4f" % s)


func test_the_server_lays_the_rocks_the_client_flags() -> void:
	var setup := _chunk()
	var client := NovaScatter.lay_chunk([setup.desc], NSIDE, IPIX, RES, setup.grid, setup.vid, setup.center)
	var server := NovaScatter.lay_chunk([setup.desc], NSIDE, IPIX, RES, setup.grid, setup.vid, setup.center, {}, [],
			true)
	var flagged := 0
	var all := 0
	var mesh: Mesh = setup.desc.meshes[0]
	for key: Array in client:
		var rows: PackedFloat32Array = client[key]
		var kept := PackedFloat32Array()
		for at in range(0, rows.size(), NovaScatter.ROW):
			all += 1
			var sc := NovaScatter.row_transform(rows, at).basis.x.length()
			var solid := NovaScatter.is_solid(mesh.get_aabb(), sc, float(setup.desc.sink))
			# The scale at the rule's edge may round either way; anywhere else the flag is the rule.
			if absf(sc - float(setup.desc.solid_scales[0])) > 1e-4:
				assert_eq(rows[at + 15] > 0.0, solid, "row flag = rule at scale %.4f" % sc)
			if rows[at + 15] > 0.0:
				assert_eq(int(rows[at + 15]), 3, "a colliding row carries its layer's slot")
				kept.append_array(rows.slice(at, at + NovaScatter.ROW))
		if not kept.is_empty():
			flagged += kept.size() / NovaScatter.ROW
			assert_eq(server.get(key, PackedFloat32Array()), kept, "the server's rows are the client's, bit for bit")
		else:
			assert_false(server.has(key), "no block of colliders where the client has none")
	assert_gt(flagged, 10, "the test chunk holds colliding rocks")
	assert_lt(flagged, all, "and rocks that do not collide")
	var parts := NovaScatter.solid_parts(server)
	assert_eq(parts.size(), flagged, "one shape a colliding rock (a model without shapes of its own: its hull)")
	for part: Array in parts:
		assert_true(part[1] is ConvexPolygonShape3D, "the hull, not the box of the bounds")


func test_a_hull_wraps_its_model_and_follows_its_rock() -> void:
	var mesh := PrismMesh.new()  # a ridge: its box is twice its volume
	mesh.size = Vector3(2.0, 1.0, 1.0)
	var shapes := NovaScatter.solid_shapes(mesh)
	assert_eq(shapes.size(), 1)
	var hull := shapes[0][0] as ConvexPolygonShape3D
	assert_not_null(hull, "a convex hull")
	assert_eq(shapes[0][1], Transform3D.IDENTITY, "in the model's own frame")
	var aabb := mesh.get_aabb().grow(0.05)  # simplified (a decomposition): its points stray a centimetre or two
	var apex := 0
	for q: Vector3 in hull.points:
		assert_true(aabb.has_point(q), "point %s within the model" % str(q))
		apex += int(q.y > 0.49)
	assert_lt(apex, 4, "the ridge's top is an edge, not the box's top face")
	assert_true(NovaScatter.solid_shapes(mesh)[0][0] == hull, "made once, shared")
	# A row (rotated, scaled 1.5): the part carries the rock's whole transform.
	var xform := Transform3D(Basis(Vector3.UP, 0.7).scaled(Vector3.ONE * 1.5), Vector3(10.0, 2.0, -3.0))
	var rows := PackedFloat32Array([xform.basis.x.x, xform.basis.y.x, xform.basis.z.x, xform.origin.x,
			xform.basis.x.y, xform.basis.y.y, xform.basis.z.y, xform.origin.y,
			xform.basis.x.z, xform.basis.y.z, xform.basis.z.z, xform.origin.z, 0, 0, 0, 2])
	var parts := NovaScatter.solid_parts({[mesh, 0, 0.0, 0]: rows})
	assert_eq(parts.size(), 1)
	assert_true((parts[0][0] as Transform3D).is_equal_approx(xform), "the rock's transform, scale included")
	assert_eq([parts[0][1], parts[0][2], parts[0][3]], [hull, 2, mesh], "its shape, slot and model")


func test_the_shapes_of_the_model_scene_win() -> void:
	var root := Node3D.new()
	var model := MeshInstance3D.new()
	model.name = "Rock"
	model.mesh = BoxMesh.new()
	root.add_child(model)
	model.owner = root
	var body := StaticBody3D.new()  # as the import's Physics > Generate makes it
	body.name = "Body"
	body.position = Vector3(0.0, 0.25, 0.0)
	root.add_child(body)
	body.owner = root
	for x: float in [-0.3, 0.3]:
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.4, 0.5, 0.9)
		cs.shape = box
		cs.position = Vector3(x, 0.0, 0.0)
		body.add_child(cs)
		cs.owner = root
	var scene := PackedScene.new()
	assert_eq(scene.pack(root), OK)
	root.free()
	var path := "user://gut_nova_rock_%d.scn" % Time.get_ticks_usec()
	assert_eq(ResourceSaver.save(scene, path), OK)
	var mesh := BoxMesh.new()
	mesh.set_meta("nova_path", path)
	var shapes := NovaScatter.solid_shapes(mesh)
	DirAccess.remove_absolute(path)
	assert_eq(shapes.size(), 2, "the scene's two shapes, no hull")
	for k in mini(shapes.size(), 2):
		assert_true(shapes[k][0] is BoxShape3D)
		assert_almost_eq((shapes[k][1] as Transform3D).origin, Vector3([-0.3, 0.3][k], 0.25, 0.0), Vector3.ONE * 1e-5,
				"shape %d placed from the scene's root (its body's offset included)" % k)


func test_the_body_holds_one_shape_a_part_on_the_world_layer() -> void:
	var box := BoxShape3D.new()
	var parts := [[Transform3D.IDENTITY, box], [Transform3D(Basis.IDENTITY, Vector3(5, 0, 0)), box]]
	var body := ROCKS.make_body(parts, "hp_n8_p1", Vector3(1, 2, 3))
	assert_eq(body.get_shape_owners().size(), 2)
	assert_true(body.get_collision_layer_value(ROCKS.GlobalsDefs.LAYER_WORLD))
	assert_eq(body.collision_mask, 0, "a static scans nothing (ADR 0013)")
	assert_eq(body.position, Vector3(1, 2, 3))
	body.free()
	assert_null(ROCKS.make_body([], "k", Vector3.ZERO), "no rock, no body")


func test_a_scaled_shape_collides_at_its_rock_size() -> void:
	# The shared shape of a 1 m box, scaled 2 by its rock's transform: Jolt must collide with a 2 m box.
	var box := BoxShape3D.new()
	box.size = Vector3.ONE
	var body := ROCKS.make_body([[Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 2.0), Vector3(5, 0, 0)), box]],
			"hp_n8_p2", Vector3.ZERO)
	add_child_autofree(body)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var from := body.global_transform * Vector3(5.0, 10.0, 0.0)
	var to := body.global_transform * Vector3(5.0, -10.0, 0.0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	var hit := body.get_world_3d().direct_space_state.intersect_ray(q)
	assert_false(hit.is_empty(), "the ray meets the rock")
	if not hit.is_empty():
		assert_almost_eq((body.global_transform.affine_inverse() * (hit.position as Vector3)).y, 1.0, 0.05,
				"on top of a 2 m box, not of a 1 m one")


func test_the_debug_view_draws_only_colliding_rocks() -> void:
	var mesh := BoxMesh.new()
	var rows := PackedFloat32Array()
	for w in [3.0, -3.0, 2.0]:
		rows.append_array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, w])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.mesh = mesh
	mmi.set_meta("nova_rows", rows)
	DEBUG_VIEW.add_boxes(mmi)
	var boxes := mmi.get_node_or_null("CollisionBoxes") as MeshInstance3D
	assert_not_null(boxes)
	assert_eq((boxes.get_meta("slots") as PackedByteArray), PackedByteArray([3, 2]), "the two colliding rows")
	var hull: Shape3D = NovaScatter.solid_shapes(mesh)[0][0]
	assert_eq((boxes.mesh as ArrayMesh).surface_get_array_len(0), 2 * DEBUG_VIEW.shape_lines(hull).size(),
			"each colliding rock drawn as its model's hull")
	mmi.free()


## A chunk of a 1000 km body with one layer of a 2 m × 1 m × 2 m model on a gently tilted grid.
func _chunk() -> Dictionary:
	var dirs: Array = HEALPix.get_pixel_grid(NSIDE, IPIX, RES)
	var center := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(NSIDE, IPIX) * RADIUS)
	var grid := PackedVector3Array()
	for yi in RES + 1:
		for xi in RES + 1:
			grid.append((dirs[yi][xi] as Vector3) * (RADIUS + 0.5 * xi + 0.2 * yi) - center)
	var vid := PackedInt32Array()
	vid.resize(grid.size())
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2.0, 1.0, 2.0)
	var sink := 0.05
	var desc := {
		"variant": 0, "slot": 3, "seed": 99, "nside": NSIDE << 5, "clump_cells": 1, "clump_share": 1.0,
		"cell_side_m": HEALPix.pixel_side_length(NSIDE << 5, RADIUS), "view_m": 300.0, "view_limit": 0.0,
		"spill": 0.0, "density": 0.5, "scale_min": 0.3, "scale_max": 1.5, "sink": sink, "align": 0.5,
		"cos_slope": 0.0, "meshes": [mesh], "heights": PackedFloat32Array([1.0]),
		"reaches": PackedFloat32Array([1.0]),
		"solid_scales": PackedFloat32Array([NovaScatter.solid_scale(mesh.get_aabb(), sink)]),
	}
	return {"grid": grid, "vid": vid, "center": center, "desc": desc}
