extends GutTest
## Suite for [NpcNavCache] — the shared navmesh boxes NPCs path on.
##
## The scheduler is driven by hand: the cache's own _physics_process is switched off, `clock` is a
## fake, the parse backend hands back a tiny solid so a bake is actually attempted, and the bake backend
## records the job instead of calling Recast — a test "lands" a bake with cache._on_bake_done(). So every
## property below is checked without a planet, a worker thread or a single real voxel:
##
##   · a crowd on one spot SHARES one box (one collection, one bake), even before the bake lands;
##   · tiles sit on a lattice of 72 m cells in a sector frame (+Y along the first requester's up), so
##     a walker crossing into the next cell gets that cell's tile; the cells along the line to the goal
##     are PREFETCHED within the block, whose tiles all share one map; there is no vertical lattice
##     (a tile spans ±64 m around its first requester's ground);
##   · boxes EXPIRE lazily (re-baked on the next request, never idle), are INVALIDATED around a point,
##     never re-bake more than once per REBAKE_MIN_INTERVAL_S, and are EVICTED once nobody uses them;
##   · one main-thread geometry collection per physics frame, server-wide;
##   · a registered obstacle (parked truck) lands in the box's source geometry, in BOX-frame space;
##   · shape extraction: trimesh + box exact, primitives as their bounding box, all wound CW-front.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_npc_nav_cache.gd

const UP := Vector3.UP

var _root: Node3D
var _cache: NpcNavCache
var _now: float = 0.0
var _parses: int = 0
var _jobs: Array = []


func before_each() -> void:
	_root = Node3D.new()
	add_child_autofree(_root)
	_cache = NpcNavCache.for_root(_root)
	# The cache's [NpcNav] diagnostics print through the OpenTelemetry bridge, which GUT counts as an
	# error per line on this machine; the rig may be armed by server.ini, so switch it off here.
	PropNet.prof_on = false
	_cache.set_physics_process(false)  # the tests pump by hand
	_now = 0.0
	_parses = 0
	_jobs = []
	_cache.clock = func() -> float: return _now
	_cache.parse_backend = func(_box: NpcNavCache.NavBox) -> Dictionary:
		_parses += 1
		var src := NavigationMeshSourceGeometryData3D.new()
		src.add_faces(NpcNavCache.box_faces(AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))), Transform3D.IDENTITY)
		return {"src": src, "task_id": -1}
	_cache.bake_backend = func(box: NpcNavCache.NavBox, mesh: NavigationMesh, _src) -> void:
		_jobs.append({"box": box, "mesh": mesh})
	NpcNavCache._parse_frame = -1
	NpcNavCache._obstacles.clear()
	NpcNavCache.perf_snapshot(true)


func after_each() -> void:
	NpcNavCache._obstacles.clear()


## Pretend a physics frame went by: the one-collection-per-frame guard lets the next pump collect.
func _next_frame() -> void:
	NpcNavCache._parse_frame = -1


## Land every recorded bake job, with one polygon on the mesh (an EMPTY bake is a special case, see
## test_empty_bake_is_retried_soon).
func _land_all(polygons: bool = true) -> void:
	var jobs: Array = _jobs
	_jobs = []
	for j in jobs:
		var mesh: NavigationMesh = j["mesh"]
		if polygons:
			mesh.set_vertices(PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)]))
			mesh.add_polygon(PackedInt32Array([0, 1, 2]))
		_cache._on_bake_done(mesh, j["box"])


func test_crowd_on_one_spot_shares_one_box_before_any_bake_lands() -> void:
	var first: NpcNavCache.NavBox = null
	for i in 50:
		var pos := Vector3(float(i) * 0.1, 0.0, float(i % 7) * 0.2)
		var box := _cache.request_box(pos, pos + Vector3(20.0, 0.0, 5.0), UP)
		if first == null:
			first = box
		assert_same(box, first, "NPC %d must share the first box" % i)
	assert_eq(_cache.box_count(), 1)
	_cache._pump()
	assert_eq(_parses, 1, "one geometry collection for the whole crowd")
	assert_eq(_jobs.size(), 1, "one bake for the whole crowd")
	assert_false(first.published)
	_land_all()
	assert_true(first.published)
	assert_eq(_cache.in_flight_count(), 0)


func test_boxes_sit_on_the_lattice_of_a_sector_aligned_with_up() -> void:
	var box := _cache.request_box(Vector3(3.0, 0.0, -2.0), Vector3(10.0, 0.0, 0.0), UP)
	# The sector opens at the first requester: its cell (0,0,0) is centred there.
	assert_almost_eq(box.frame.position, Vector3(3.0, 0.0, -2.0), Vector3.ONE * 0.001)
	assert_almost_eq(box.frame.basis.y, UP, Vector3.ONE * 0.001)
	assert_eq(_cache.sector_count(), 1)
	# 500 m away, same sector: the box lands on the lattice (multiples of 72 m from the origin).
	var far := _cache.request_box(Vector3(3.0 + 500.0, 0.0, -2.0), Vector3(3.0 + 510.0, 0.0, -2.0), UP)
	assert_eq(far.cell, Vector3i(7, 0, 0))
	assert_almost_eq(far.frame.position, Vector3(3.0 + 7.0 * NpcNavCache.LATTICE_XZ, 0.0, -2.0), Vector3.ONE * 0.001)
	assert_eq(_cache.sector_count(), 1)
	# A tilted up opens a tilted sector only when out of reach of the first one.
	var tilted := Vector3(1.0, 1.0, 0.0).normalized()
	var beyond := Vector3(0.0, 0.0, NpcNavCache.SECTOR_RADIUS + 100.0)
	var box2 := _cache.request_box(beyond, beyond + Vector3(0.0, 0.0, 10.0), tilted)
	assert_eq(_cache.sector_count(), 2)
	assert_almost_eq(box2.frame.basis.y, tilted, Vector3.ONE * 0.001)
	assert_almost_eq(box2.frame.basis.y.dot(box2.frame.basis.x), 0.0, 0.001)


func test_leaving_the_cell_requests_the_neighbour_box() -> void:
	var a := _cache.request_box(Vector3.ZERO, Vector3(10.0, 0.0, 0.0), UP)  # cell (0,0,0), ±36
	var inside := _cache.request_box(Vector3(30.0, 0.0, 20.0), Vector3(30.0, 0.0, 0.0), UP)
	assert_same(inside, a, "30 m from the centre: same cell")
	assert_eq(_cache.box_count(), 1, "goal pointing back inside: nothing prefetched")
	var edge := _cache.request_box(Vector3(0.0, 0.0, 40.0), Vector3(0.0, 0.0, 41.0), UP)
	assert_ne(edge, a, "40 m out is the next cell")
	assert_eq(edge.cell, Vector3i(0, 0, 1))
	var high := _cache.request_box(Vector3(0.0, 30.0, 0.0), Vector3(1.0, 30.0, 0.0), UP)
	assert_same(high, a, "30 m up is still this tile: no vertical lattice, ±64 m around its ground")
	assert_true(a.covers(Vector3(0.0, 60.0, 0.0), 0.0))
	assert_false(a.covers(Vector3(0.0, 70.0, 0.0), 0.0), "beyond ±(64 - 2) m: not covered")
	var slope := _cache.request_box(Vector3(0.0, -40.0, 150.0), Vector3(0.0, -40.0, 160.0), UP)
	assert_almost_eq(slope.centre.y, -40.0, 0.001, "a new tile is centred on its requester's ground height")


func test_corridor_to_the_goal_is_prefetched_within_the_block() -> void:
	var a := _cache.request_box(Vector3.ZERO, Vector3(100.0, 0.0, 0.0), UP)
	assert_eq(_cache.box_count(), 2, "cells 0 and 1 (the goal at 100 m is in cell 1): the corridor")
	assert_eq(a.cell, Vector3i.ZERO)
	var same := _cache.request_box(Vector3(28.0, 0.0, 0.0), Vector3(100.0, 0.0, 0.0), UP)
	assert_same(same, a, "still in the cell")
	assert_eq(_cache.box_count(), 2)
	var same2 := _cache.request_box(Vector3(28.0, 0.0, 0.0), Vector3(-100.0, 0.0, 0.0), UP)
	assert_same(same2, a)
	assert_eq(_cache.box_count(), 3, "heading the other way: cell -1")
	# Every tile of the block shares the block's map; a goal beyond the block prefetches no further.
	var b := _cache.request_box(Vector3(72.0, 0.0, 0.0), Vector3(1000.0, 0.0, 0.0), UP)
	assert_eq(b.map, a.map, "same block, same map")
	assert_true(_cache.box_count() <= 3 + NpcNavCache.PREFETCH_MAX_CELLS)
	for box in _cache._boxes:
		assert_eq(box.block.key.x, 0, "nothing prefetched outside block 0")


func test_expired_box_is_rebaked_lazily_on_request_and_stays_published() -> void:
	var box := _cache.request_box(Vector3.ZERO, Vector3(10.0, 0.0, 0.0), UP)
	_cache._pump()
	_land_all()
	assert_eq(box.baked_at, 0.0)
	_now = NpcNavCache.box_ttl_s + 10.0
	_cache._pump()
	assert_eq(_jobs.size(), 0, "an expired box nobody asks for is never re-baked")
	assert_same(_cache.request_box(Vector3(1.0, 0.0, 0.0), Vector3(10.0, 0.0, 0.0), UP), box)
	assert_eq(_cache.queued_count(), 1)
	_next_frame()
	_cache._pump()
	assert_eq(_jobs.size(), 1, "re-bake started")
	assert_true(box.published, "the old mesh keeps serving while the re-bake runs")
	_land_all()
	assert_eq(box.baked_at, _now)
	assert_true(box.is_fresh(_now, NpcNavCache.box_ttl_s))


func test_empty_bake_is_retried_soon() -> void:
	var box := _cache.request_box(Vector3.ZERO, Vector3(10.0, 0.0, 0.0), UP)
	_cache._pump()
	_land_all(false)  # nothing solid was collected (chunks not resident yet): zero polygons
	assert_true(box.published)
	_now = NpcNavCache.EMPTY_RETRY_S - 1.0
	_cache.request_box(Vector3.ZERO, Vector3(10.0, 0.0, 0.0), UP)
	assert_eq(_cache.queued_count(), 0, "not yet")
	_now = NpcNavCache.EMPTY_RETRY_S + 1.0
	_cache.request_box(Vector3.ZERO, Vector3(10.0, 0.0, 0.0), UP)
	assert_eq(_cache.queued_count(), 1, "an empty bake expires after EMPTY_RETRY_S, not box_ttl_s")


func test_invalidate_around_marks_boxes_dirty_by_distance_and_age() -> void:
	var box := _cache.request_box(Vector3.ZERO, Vector3(10.0, 0.0, 0.0), UP)  # covers x, z -36..36
	_cache._pump()
	_land_all()
	_cache.invalidate_around(Vector3(0.0, 0.0, 300.0), 5.0)
	assert_false(box.dirty, "300 m away: untouched")
	_cache.invalidate_around(Vector3(0.0, 0.0, 40.0), 5.0, 10.0)
	assert_false(box.dirty, "4 m outside the edge but baked 0 s ago with min_age 10 s: untouched")
	_now = 20.0
	_cache.invalidate_around(Vector3(0.0, 0.0, 40.0), 5.0, 10.0)
	assert_true(box.dirty, "4 m outside the edge, within the 5 m radius: dirty")
	assert_true(box.parse_dirty)
	assert_false(box.is_fresh(_now, NpcNavCache.box_ttl_s))
	# Static entry point reaches every live cache.
	box.dirty = false
	NpcNavCache.invalidate_around_all(Vector3(10.0, 0.0, 0.0), 1.0)
	assert_true(box.dirty)


func test_rebake_is_rate_limited_and_a_dirty_baking_box_requeues_itself() -> void:
	var box := _cache.request_box(Vector3.ZERO, Vector3(10.0, 0.0, 0.0), UP)
	_cache._pump()
	_land_all()
	_now = 1.0
	_cache.invalidate_around(Vector3.ZERO, 1.0)
	_cache.request_box(Vector3.ZERO, Vector3(10.0, 0.0, 0.0), UP)
	_next_frame()
	_cache._pump()
	assert_eq(_jobs.size(), 0, "1 s after landing: too soon to re-bake")
	assert_eq(_cache.queued_count(), 1, "but it stays queued")
	_now = NpcNavCache.REBAKE_MIN_INTERVAL_S + 1.0
	_next_frame()
	_cache._pump()
	assert_eq(_jobs.size(), 1, "past the interval: re-bake starts")
	assert_false(box.dirty)
	_cache.invalidate_around(Vector3.ZERO, 1.0)  # world changes again while Recast runs
	_cache.request_box(Vector3.ZERO, Vector3(10.0, 0.0, 0.0), UP)
	assert_eq(_cache.queued_count(), 0, "a running job is not queued twice")
	_now += 1.0
	_land_all()
	assert_true(box.published)
	assert_eq(_cache.queued_count(), 1, "re-dirtied during the bake: queued again on landing")


func test_unused_box_is_evicted_and_a_held_one_survives() -> void:
	var idle := _cache.request_box(Vector3.ZERO, Vector3(10.0, 0.0, 0.0), UP)
	var held := _cache.request_box(Vector3(0.0, 0.0, 300.0), Vector3(0.0, 0.0, 310.0), UP)
	_cache._pump()
	_cache._pump()
	_land_all()
	_cache.acquire(held)
	assert_true(idle.map.is_valid())
	_now = NpcNavCache.box_evict_s + 1.0
	_cache._pump()
	assert_true(idle.freed)
	assert_false(idle.map.is_valid(), "map freed with the box")
	assert_false(held.freed)
	assert_eq(_cache.box_count(), 1)
	_cache.release(held)
	_now += NpcNavCache.box_evict_s + 1.0
	_cache._pump()
	assert_true(held.freed)
	assert_eq(_cache.box_count(), 0)


func test_one_geometry_collection_per_physics_frame() -> void:
	_cache.request_box(Vector3.ZERO, Vector3(10.0, 0.0, 0.0), UP)
	_cache.request_box(Vector3(0.0, 0.0, 300.0), Vector3(0.0, 0.0, 310.0), UP)
	_cache._pump()
	assert_eq(_parses, 1, "second box waits for the next frame")
	assert_eq(_cache.queued_count(), 1)
	_cache._pump()
	assert_eq(_parses, 1, "same frame: still waiting")
	await get_tree().physics_frame
	await get_tree().physics_frame
	_cache._pump()
	assert_eq(_parses, 2)
	assert_eq(_cache.queued_count(), 0)


func test_registered_obstacle_is_projected_into_the_box_frame() -> void:
	var truck := Node3D.new()
	_root.add_child(truck)
	truck.position = Vector3(30.0, 0.0, 5.0)
	truck.rotation = Vector3(0.0, PI / 2.0, 0.0)
	var verts := PackedVector3Array([Vector3(-4, 0, -1.5), Vector3(4, 0, -1.5), Vector3(4, 0, 1.5), Vector3(-4, 0, 1.5)])
	NpcNavCache.set_static_obstacle(truck, verts, 0.2, 3.0, true)
	assert_eq(NpcNavCache.obstacle_count(), 1)
	var box := _cache.request_box(Vector3.ZERO, Vector3(30.0, 0.0, 0.0), UP)  # cell (0,0,0), centre at 0
	_cache._pump()
	var obs: Array = box.parse.get_projected_obstructions()
	assert_eq(obs.size(), 1)
	if obs.size() == 1:
		assert_almost_eq(float(obs[0]["elevation"]), 0.2 - 0.5, 0.001, "lowest corner minus 0.5 m, in box frame")
		assert_almost_eq(float(obs[0]["height"]), 4.0, 0.001)
		var flat: PackedFloat32Array = obs[0]["vertices"]
		assert_eq(flat.size(), 12)
		# The truck sits 30 m +X of the box centre, rotated 90 deg: its 8 m length now runs along Z.
		var xs: Array = [flat[0], flat[3], flat[6], flat[9]]
		var zs: Array = [flat[2], flat[5], flat[8], flat[11]]
		assert_almost_eq(float(xs.max() - xs.min()), 3.0, 0.01)
		assert_almost_eq(float(zs.max() - zs.min()), 8.0, 0.01)
		assert_almost_eq(float(xs.max() + xs.min()) * 0.5, 30.0, 0.01)
	# A far obstacle is skipped; a cleared one is forgotten.
	var far := Node3D.new()
	_root.add_child(far)
	far.position = Vector3(0.0, 0.0, 400.0)
	NpcNavCache.set_static_obstacle(far, verts, 0.0, 3.0)
	var box2 := _cache.request_box(Vector3.ZERO, Vector3(30.0, 0.0, 0.0), UP)
	assert_same(box2, box)
	box.parse_dirty = true
	_cache.invalidate_around(Vector3.ZERO, 1.0)
	_land_all()
	_now = 100.0
	_next_frame()
	_cache._pump()
	assert_eq(box.parse.get_projected_obstructions().size(), 1, "the 400 m obstacle does not reach this box")
	NpcNavCache.clear_static_obstacle(truck)
	NpcNavCache.clear_static_obstacle(far)
	assert_eq(NpcNavCache.obstacle_count(), 0)


func test_box_faces_are_wound_clockwise_front() -> void:
	var bb := AABB(Vector3(-1, -2, -3), Vector3(2, 4, 6))
	var faces := NpcNavCache.box_faces(bb)
	assert_eq(faces.size(), 36)
	for i in range(0, faces.size(), 3):
		var a: Vector3 = faces[i]
		var b: Vector3 = faces[i + 1]
		var c: Vector3 = faces[i + 2]
		var n: Vector3 = (b - a).cross(c - a)
		var centroid: Vector3 = (a + b + c) / 3.0
		assert_lt(n.dot(centroid - bb.get_center()), 0.0, "triangle %d: geometric normal must point inward" % (i / 3))


func test_shape_faces_exact_for_trimesh_and_box_bounding_box_for_the_rest() -> void:
	var tri := ConcavePolygonShape3D.new()
	tri.set_faces(PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1),
			Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)]))
	assert_eq(NpcNavCache.shape_faces(tri).size(), 6)
	var box := BoxShape3D.new()
	box.size = Vector3(2, 4, 6)
	assert_eq(NpcNavCache.shape_faces(box).size(), 36)
	var sphere := SphereShape3D.new()
	sphere.radius = 1.5
	var sf := NpcNavCache.shape_faces(sphere)
	assert_eq(sf.size(), 36)
	var sb := AABB(sf[0], Vector3.ZERO)
	for v in sf:
		sb = sb.expand(v)
	assert_almost_eq(sb.size, Vector3(3, 3, 3), Vector3.ONE * 0.001)
	var convex := ConvexPolygonShape3D.new()
	convex.points = PackedVector3Array([Vector3(0, 0, 0), Vector3(2, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 3)])
	var cf := NpcNavCache.shape_faces(convex)
	assert_eq(cf.size(), 36)
	var cb := AABB(cf[0], Vector3.ZERO)
	for v in cf:
		cb = cb.expand(v)
	assert_almost_eq(cb.position, Vector3.ZERO, Vector3.ONE * 0.001)
	assert_almost_eq(cb.size, Vector3(2, 1, 3), Vector3.ONE * 0.001)
	assert_eq(NpcNavCache.shape_faces(WorldBoundaryShape3D.new()).size(), 0)


func test_extract_adds_transformed_faces_of_every_entry() -> void:
	var tri := ConcavePolygonShape3D.new()
	tri.set_faces(PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)]))
	var src := NavigationMeshSourceGeometryData3D.new()
	var shift := Transform3D(Basis.IDENTITY, Vector3(5, 0, 0))
	NpcNavCache._extract([
		{"shape": tri, "xform": shift},
		{"shape": BoxShape3D.new(), "xform": Transform3D.IDENTITY},
		{"faces": PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)]), "xform": shift},
		{"shape": WorldBoundaryShape3D.new(), "xform": Transform3D.IDENTITY},
	], src)
	assert_true(src.has_data())
	var verts: PackedFloat32Array = src.get_vertices()
	assert_eq(verts.size(), (1 + 12 + 1) * 3 * 3, "1 + 12 + 1 triangles, 3 vertices each, xyz")
	assert_almost_eq(float(verts[0]), 5.0, 0.001, "the trimesh vertex was shifted by its xform")


func test_entries_from_hits_keeps_static_bodies_only_and_dedupes() -> void:
	var body := StaticBody3D.new()
	_root.add_child(body)
	body.position = Vector3(10, 0, 0)
	var cs := CollisionShape3D.new()
	cs.shape = BoxShape3D.new()
	cs.position = Vector3(0, 1, 0)
	body.add_child(cs)
	var rigid := RigidBody3D.new()
	_root.add_child(rigid)
	var rcs := CollisionShape3D.new()
	rcs.shape = BoxShape3D.new()
	rigid.add_child(rcs)
	var hit := {"collider": body, "collider_id": body.get_instance_id(), "shape": 0, "rid": body.get_rid()}
	var frame_inv := Transform3D(Basis.IDENTITY, Vector3(-24, 0, 0))
	var entries := NpcNavCache.entries_from_hits([
		hit, hit.duplicate(),
		{"collider": rigid, "collider_id": rigid.get_instance_id(), "shape": 0, "rid": rigid.get_rid()},
		{"collider": null, "collider_id": 0, "shape": 0, "rid": RID()},
	], frame_inv)
	assert_eq(entries.size(), 1, "the static body once, the rigid body never")
	if entries.size() == 1:
		assert_same(entries[0]["shape"], cs.shape)
		assert_almost_eq((entries[0]["xform"] as Transform3D).origin, Vector3(-14, 1, 0), Vector3.ONE * 0.001)


func test_perf_snapshot_counts_and_resets() -> void:
	_cache.request_box(Vector3.ZERO, Vector3(10.0, 0.0, 0.0), UP)
	_cache._pump()
	var snap := NpcNavCache.perf_snapshot(false)
	assert_eq(snap["boxes"], 1)
	assert_eq(snap["parses"], 1)
	assert_eq(snap["inflight"], 1)
	assert_eq(snap["bakes"], 0)
	_now = 0.25
	_land_all()
	snap = NpcNavCache.perf_snapshot(true)
	assert_eq(snap["bakes"], 1)
	assert_eq(snap["bake_usec"], 250000)
	assert_eq(NpcNavCache.perf_snapshot(false)["bakes"], 0, "reset")
