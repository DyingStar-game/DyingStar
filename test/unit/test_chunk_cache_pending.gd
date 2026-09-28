extends GutTest
## ChunkDiskCache's worker-side write: write_mesh_pending leaves the mesh in a
## temporary file nothing reads, commit_pending publishes it (load_mesh then
## finds it), discard_pending and the next session's init drop it — and a
## threaded read (PlanetTerrain._request_cache_load) gets the same mesh back.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_chunk_cache_pending.gd

const ROOT := "user://test_chunk_cache_pending/"
const PLANET := "probe"


func _wipe() -> void:
	var dir := DirAccess.open(ROOT + PLANET)
	if dir != null:
		for f in dir.get_files():
			dir.remove(f)


func before_each() -> void:
	_wipe()


func after_all() -> void:
	_wipe()


func _mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.add_vertex(Vector3(0, 0, 0))
	st.add_vertex(Vector3(1, 0, 0))
	st.add_vertex(Vector3(0, 0, 1))
	var m := st.commit()
	m.set_meta("probe", 7)
	return m


func _files() -> PackedStringArray:
	var dir := DirAccess.open(ROOT + PLANET)
	return dir.get_files() if dir != null else PackedStringArray()


func _tmp_count() -> int:
	var n := 0
	for f in _files():
		if ".tmp." in f:
			n += 1
	return n


func test_pending_write_is_invisible_until_committed() -> void:
	var cache := ChunkDiskCache.new(PLANET, "v1", ROOT)
	var tmp := cache.write_mesh_pending("hp_n8_p3", 2, _mesh(), 5)
	assert_ne(tmp, "", "written")
	assert_false(cache.has_mesh("hp_n8_p3", 2, 5), "not published yet")
	assert_eq(_tmp_count(), 1)
	cache.commit_pending(tmp, "hp_n8_p3", 2, 5)
	assert_true(cache.has_mesh("hp_n8_p3", 2, 5), "published by the rename")
	assert_eq(_tmp_count(), 0)
	assert_eq(cache.cache_saves, 1)
	var back := cache.load_mesh("hp_n8_p3", 2, 5)
	assert_not_null(back)
	assert_eq(int(back.get_meta("probe", 0)), 7, "the mesh and its metas round-trip")


func test_discard_and_stale_files_are_dropped() -> void:
	var cache := ChunkDiskCache.new(PLANET, "v1", ROOT)
	var tmp := cache.write_mesh_pending("hp_n8_p4", 2, _mesh())
	ChunkDiskCache.discard_pending(tmp)
	assert_eq(_tmp_count(), 0, "discarded")
	assert_false(cache.has_mesh("hp_n8_p4", 2))
	# A write the previous session never published.
	cache.write_mesh_pending("hp_n8_p5", 2, _mesh())
	assert_eq(_tmp_count(), 1)
	var _next := ChunkDiskCache.new(PLANET, "v1", ROOT)
	assert_eq(_tmp_count(), 0, "the next session drops it")


func test_worker_write_then_threaded_read() -> void:
	var cache := ChunkDiskCache.new(PLANET, "v1", ROOT)
	var mesh := _mesh()
	var out: Array = [""]
	var tid := WorkerThreadPool.add_task(func():
		out[0] = cache.write_mesh_pending("hp_n16_p9", 3, mesh))
	# Polled frame by frame as PlanetTerrain does: the save reads the mesh
	# back through the RenderingServer, which a blocked main thread starves.
	var t0 := Time.get_ticks_msec()
	while not WorkerThreadPool.is_task_completed(tid) and Time.get_ticks_msec() - t0 < 5000:
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(tid)
	assert_ne(String(out[0]), "", "written from the worker")
	cache.commit_pending(String(out[0]), "hp_n16_p9", 3)
	var path := cache.mesh_path("hp_n16_p9", 3)
	assert_eq(ResourceLoader.load_threaded_request(path, "", false,
			ResourceLoader.CACHE_MODE_IGNORE), OK)
	t0 = Time.get_ticks_msec()
	while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS \
			and Time.get_ticks_msec() - t0 < 5000:
		await get_tree().process_frame
	assert_eq(ResourceLoader.load_threaded_get_status(path), ResourceLoader.THREAD_LOAD_LOADED)
	var back := ResourceLoader.load_threaded_get(path) as ArrayMesh
	assert_not_null(back)
	assert_eq(back.get_surface_count(), 1)
