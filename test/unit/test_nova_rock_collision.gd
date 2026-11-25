extends GutTest
## The colliders of Nova's scattered rocks: which rocks collide (NovaScatter.is_solid), that the server's
## solid-only laying gives exactly the rocks the client draws as colliding, at the same place, and the
## debug view's boxes (Settings > Debug).
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
	var boxes := NovaScatter.solid_boxes(server)
	assert_eq(boxes.size(), flagged, "one box a colliding rock")


func test_a_box_wraps_its_rock_where_it_is_drawn() -> void:
	var aabb := AABB(Vector3(-1.0, 0.0, -0.5), Vector3(2.0, 1.0, 1.0))
	var xform := Transform3D(Basis(Vector3.UP, 0.7).scaled(Vector3.ONE * 1.5), Vector3(10.0, 2.0, -3.0))
	var box := NovaScatter.solid_box(aabb, xform)
	assert_almost_eq((box[1] as Vector3), Vector3(3.0, 1.5, 1.5), Vector3.ONE * 1e-5, "scaled bounds")
	assert_almost_eq((box[0] as Transform3D).origin, xform * aabb.get_center(), Vector3.ONE * 1e-4, "at its middle")
	for c in 8:
		var corner := aabb.position + aabb.size * Vector3(c & 1, (c >> 1) & 1, (c >> 2) & 1)
		var in_box: Vector3 = (box[0] as Transform3D).affine_inverse() * (xform * corner)
		assert_almost_eq(in_box.abs(), (box[1] as Vector3) * 0.5, Vector3.ONE * 1e-3, "corner %d on the box" % c)


func test_the_body_holds_one_box_a_rock_on_the_world_layer() -> void:
	var boxes := [[Transform3D.IDENTITY, Vector3(2, 1, 2)], [Transform3D(Basis.IDENTITY, Vector3(5, 0, 0)), Vector3.ONE]]
	var body := ROCKS.make_body(boxes, "hp_n8_p1", Vector3(1, 2, 3))
	assert_eq(body.get_shape_owners().size(), 2)
	assert_true(body.get_collision_layer_value(ROCKS.GlobalsDefs.LAYER_WORLD))
	assert_eq(body.collision_mask, 0, "a static scans nothing (ADR 0013)")
	assert_eq(body.position, Vector3(1, 2, 3))
	body.free()
	assert_null(ROCKS.make_body([], "k", Vector3.ZERO), "no rock, no body")


func test_the_debug_view_boxes_only_colliding_rocks() -> void:
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
	assert_eq((boxes.mesh as ArrayMesh).surface_get_array_len(0), 2 * DEBUG_VIEW.EDGES.size(), "12 edges a box")
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
