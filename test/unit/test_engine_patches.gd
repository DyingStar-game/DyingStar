extends GutTest
## The game runs on its own engine build (DyingStar-game/godotandaddons, patches/): these check the patches that
## can be seen from a script are in the engine running the tests. A failure here = a stock Godot, or a release
## built without that patch.

## How far from the origin (m): a planet's distance to its star, where PR #512 measured the lamps' shadows.
const FAR_M := 8.5e10
## How far the instance moves (m): a step of the planet is ~137 km, far below the old relative 1e-5 (850 km here).
const MOVE_M := 1000.0


## godotandaddons patch 0003: DynamicBVH::update compares exactly. With the stock relative tolerance, the
## rendering tree kept an instance where it was until it had moved by more than 1e-5 of its coordinate, and an
## omni or spot light found no shadow caster where it now stood.
func test_the_render_tree_follows_a_small_move_far_from_the_origin() -> void:
	var rs := RenderingServer
	var scenario: RID = rs.scenario_create()
	var mesh: RID = rs.mesh_create()
	var instance: RID = rs.instance_create2(mesh, scenario)
	var marker := RefCounted.new()  # instances_cull_aabb answers the object ids attached to the instances
	rs.instance_attach_object_instance_id(instance, marker.get_instance_id())
	rs.instance_set_custom_aabb(instance, AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2)))
	var start := Vector3(FAR_M, 0.0, 0.0)
	rs.instance_set_transform(instance, Transform3D(Basis.IDENTITY, start))
	assert_true(_found(marker, start, scenario), "indexed where it was placed")

	var moved := start + Vector3(MOVE_M, 0.0, 0.0)
	rs.instance_set_transform(instance, Transform3D(Basis.IDENTITY, moved))
	assert_true(_found(marker, moved, scenario),
			"found where it moved: without godotandaddons patch 0003 the tree keeps it %d m behind" % MOVE_M)
	assert_false(_found(marker, start, scenario), "no longer where it was")

	rs.free_rid(instance)
	rs.free_rid(mesh)
	rs.free_rid(scenario)


## godotandaddons patch 0004: a path to an unreachable target leads to the closest reachable point. The engine
## finds it in a second pass of the search, which kept the polygon count of the first one: a reachable area of
## more than half of path_search_max_polygons (4096) ran out of budget, printed "It's not expect to not find the
## most reachable polygons" and returned a path that never left the begin polygon (NPCs standing still).
func test_a_path_to_an_unreachable_target_leads_to_the_closest_reachable_point() -> void:
	const STRIP := 2500  # polygons of the reachable strip: over 4096 / 2, under 4096
	var map: RID = NavigationServer3D.map_create()
	NavigationServer3D.map_set_active(map, true)
	var reachable: RID = _strip_region(map, STRIP, 0.0)
	var island: RID = _strip_region(map, 2, STRIP + 50.0)  # 50 m past the end of the strip: no way there
	var start := Vector3(0.5, 0.0, 0.5)
	var target := Vector3(STRIP + 51.0, 0.0, 0.5)
	for i in 600:  # the map takes its regions asynchronously; querying it before its first sync is an error
		await get_tree().physics_frame
		if NavigationServer3D.map_get_iteration_id(map) > 0 \
				and NavigationServer3D.map_get_closest_point(map, start).is_equal_approx(start) \
				and NavigationServer3D.map_get_closest_point(map, target).is_equal_approx(target):
			break
	var path := NavigationServer3D.map_get_path(map, start, target, true)
	assert_gt(path.size(), 2, "a path along the strip, not one that stays in the begin polygon")
	if path.size() > 0:
		assert_almost_eq(path[path.size() - 1].x, float(STRIP), 0.01,
				"the path ends at the end of the strip: without godotandaddons patch 0004 it stops at the start")
	NavigationServer3D.free_rid(reachable)
	NavigationServer3D.free_rid(island)
	NavigationServer3D.free_rid(map)


## A region on [param map] holding a strip of [param count] 1 m square polygons, joined edge to edge along +X
## from x = [param x0].
func _strip_region(map: RID, count: int, x0: float) -> RID:
	var mesh := NavigationMesh.new()
	var vertices := PackedVector3Array()
	for i in count + 1:
		vertices.push_back(Vector3(x0 + i, 0.0, 0.0))
		vertices.push_back(Vector3(x0 + i, 0.0, 1.0))
	mesh.vertices = vertices
	for i in count:
		mesh.add_polygon(PackedInt32Array([i * 2, i * 2 + 1, i * 2 + 3, i * 2 + 2]))
	var region: RID = NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(region, map)
	NavigationServer3D.region_set_navigation_mesh(region, mesh)
	return region


## Does the rendering tree of [param scenario] hold the instance of [param marker] within 10 m of [param at]?
func _found(marker: Object, at: Vector3, scenario: RID) -> bool:
	var box := AABB(at - Vector3.ONE * 10.0, Vector3.ONE * 20.0)
	return RenderingServer.instances_cull_aabb(box, scenario).has(marker.get_instance_id())
