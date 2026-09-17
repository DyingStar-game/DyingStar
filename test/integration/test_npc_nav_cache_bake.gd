extends GutTest
## End-to-end bake through [NpcNavCache] with the REAL backends: physics broadphase query, worker face
## extraction, asynchronous Recast bake, region publish, then a path query on the shared map.
##
## World: a 60 x 60 m floor, a 20 m wall across the direct route, and later a "parked truck" registered
## as a carved obstacle. Expectations:
##   · the bake lands (published) within a few seconds and has polygons;
##   · a route from (0,0,0) to (10,0,0) exists and goes AROUND the wall (much longer than 10 m);
##   · after a truck parks on the route and the box is invalidated + re-requested, the re-bake carves a
##     hole where the truck stands.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/integration/test_npc_nav_cache_bake.gd

const UP := Vector3.UP
const BAKE_TIMEOUT_S := 20.0

var _root: Node3D
var _cache: NpcNavCache


func _solid(size: Vector3, at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1  # world
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	body.position = at
	_root.add_child(body)
	return body


func before_each() -> void:
	_root = Node3D.new()
	add_child_autofree(_root)
	_solid(Vector3(200.0, 1.0, 200.0), Vector3(0.0, -0.5, 0.0))  # floor, top face at y = 0 (3 cells wide)
	_solid(Vector3(1.0, 3.0, 20.0), Vector3(5.0, 1.5, 0.0))     # wall across the route, z -10..10
	_cache = NpcNavCache.for_root(_root)
	# The cache's [NpcNav] diagnostics print through the OpenTelemetry bridge, which GUT counts as an
	# error per line on this machine; the rig may be armed by server.ini, so switch it off here.
	PropNet.prof_on = false
	NpcNavCache._obstacles.clear()
	await get_tree().physics_frame
	await get_tree().physics_frame  # bodies registered with the physics server


func after_each() -> void:
	NpcNavCache._obstacles.clear()


func _wait_published(box: NpcNavCache.NavBox, after: float) -> bool:
	var t0: float = Time.get_ticks_msec() / 1000.0
	while Time.get_ticks_msec() / 1000.0 - t0 < BAKE_TIMEOUT_S:
		if box.published and box.baked_at > after:
			return true
		await get_tree().physics_frame
	return false


func test_real_bake_paths_around_the_wall_and_a_parked_truck_carves_a_hole() -> void:
	var start := Vector3.ZERO
	var goal := Vector3(10.0, 0.0, 0.0)
	var box := _cache.request_box(start, goal, UP)
	assert_false(box.published)
	assert_true(await _wait_published(box, -1.0), "bake landed within %d s" % int(BAKE_TIMEOUT_S))
	if not box.published:
		return
	assert_gt(box.mesh.get_polygon_count(), 0, "the floor baked into polygons")
	assert_true(box.parse == null, "the collection is dropped once the bake lands")
	# Let the map iteration (async) pick up the region.
	for i in 10:
		await get_tree().physics_frame
	assert_gt(NavigationServer3D.map_get_iteration_id(box.map), 0)
	var path := NavigationServer3D.map_get_path(box.map, box.to_local(start), box.to_local(goal), true)
	assert_gt(path.size(), 2, "a multi-corner route exists")
	var length := 0.0
	for i in range(1, path.size()):
		length += path[i].distance_to(path[i - 1])
	assert_gt(length, 20.0, "the route goes around the 20 m wall, not through it (length %.1f m)" % length)
	if path.size() > 0:
		assert_lt(box.from_local(path[path.size() - 1]).distance_to(goal), 1.0, "…and reaches the goal")
	# Recast is surface-based: the inside of a closed 3 m box gets a sliver of "floor" with enough
	# headroom, so the wall's interior IS mesh — a sealed island. What matters is that it is unreachable.
	var into_wall := NavigationServer3D.map_get_path(box.map, box.to_local(start), box.to_local(Vector3(5.0, 0.0, 0.0)), true)
	assert_gt(into_wall.size(), 0)
	if into_wall.size() > 0:
		assert_gt(box.from_local(into_wall[into_wall.size() - 1]).distance_to(Vector3(5.0, 0.0, 0.0)), 0.5,
				"a route INTO the wall stops short of it")

	# A truck parks at (-6, 0, 0): a 6 x 3 m footprint, 3 m tall.
	var truck := Node3D.new()
	_root.add_child(truck)
	truck.position = Vector3(-6.0, 0.4, 0.0)
	NpcNavCache.set_static_obstacle(truck, PackedVector3Array([
		Vector3(-3, 0, -1.5), Vector3(3, 0, -1.5), Vector3(3, 0, 1.5), Vector3(-3, 0, 1.5)]), -0.4, 3.0, true)
	var before_truck := NavigationServer3D.map_get_closest_point(box.map, box.to_local(truck.position))
	assert_lt(before_truck.distance_to(box.to_local(Vector3(-6.0, 0.0, 0.0))), 0.3, "walkable there before the truck")
	var landed_at: float = box.baked_at
	NpcNavCache.invalidate_around_all(truck.position, 5.0)
	assert_true(box.dirty)
	# The NPC loop asks again; the cache re-queues (rate-limited to REBAKE_MIN_INTERVAL_S after the last).
	var again := _cache.request_box(start, goal, UP)
	assert_same(again, box, "same shared box, re-baked in place")
	assert_true(await _wait_published(box, landed_at), "re-bake landed")
	for i in 10:
		await get_tree().physics_frame
	var after_truck := NavigationServer3D.map_get_closest_point(box.map, box.to_local(Vector3(-6.0, 0.0, 0.0)))
	assert_gt(after_truck.distance_to(box.to_local(Vector3(-6.0, 0.0, 0.0))), 1.0,
			"the parked truck carved a hole under itself (nearest mesh %.2f m away)"
			% after_truck.distance_to(box.to_local(Vector3(-6.0, 0.0, 0.0))))
	NpcNavCache.clear_static_obstacle(truck)


func test_a_route_crosses_the_seam_between_two_tiles() -> void:
	# The goal sits in the next cell (+X): its tile is prefetched with ours, both land on the block's
	# shared map, and the path must run through the tile boundary at x = 36 as if it were not there.
	var start := Vector3(10.0, 0.0, 0.0)
	var goal := Vector3(70.0, 0.0, 0.0)
	var box := _cache.request_box(start, goal, UP)
	assert_eq(_cache.box_count(), 2, "own cell + the goal's cell")
	var next: NpcNavCache.NavBox = null
	for b in _cache._boxes:
		if b != box:
			next = b
	assert_eq(next.cell, Vector3i(1, 0, 0))
	assert_eq(next.map, box.map, "one map for the block")
	assert_true(await _wait_published(box, -1.0), "tile 0 baked")
	assert_true(await _wait_published(next, -1.0), "tile 1 baked")
	for i in 10:
		await get_tree().physics_frame
	var path := NavigationServer3D.map_get_path(box.map, box.to_local(start), box.to_local(goal), true)
	assert_gt(path.size(), 1)
	if path.size() > 0:
		var end_gap: float = box.from_local(path[path.size() - 1]).distance_to(goal)
		assert_lt(end_gap, 1.0, "the route reaches a goal on the OTHER tile (ends %.2f m short)" % end_gap)
	# And the closest-point on the seam itself is on the mesh (no eroded gap between the tiles).
	var on_seam := NavigationServer3D.map_get_closest_point(box.map, box.to_local(Vector3(36.0, 0.0, 0.0)))
	assert_lt(on_seam.distance_to(box.to_local(Vector3(36.0, 0.0, 0.0))), 0.35, "mesh continuous across x = 36")
