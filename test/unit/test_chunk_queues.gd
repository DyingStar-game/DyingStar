extends GutTest
## The cached mesh's first vertex survives a save (ChunkDiskCache.stamp_first_vertex), and the
## build / assembly queues serve their best item first from the END (PlanetTerrain._queue_insert).

const TMP := "user://test_chunk_queues_mesh.res"


func _quad() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(1, 2, 3), Vector3(4, 5, 6), Vector3(7, 8, 9)])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func after_all() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


func test_the_first_vertex_is_read_back_from_the_saved_file() -> void:
	var mesh := _quad()
	ChunkDiskCache.stamp_first_vertex(mesh)
	assert_eq(ResourceSaver.save(mesh, TMP, ResourceSaver.FLAG_COMPRESS), OK)
	var back := ResourceLoader.load(TMP, "", ResourceLoader.CACHE_MODE_IGNORE) as ArrayMesh
	assert_true(back.has_meta(ChunkDiskCache.FIRST_VERTEX_META), "the metadata is saved with the mesh")
	assert_eq(ChunkDiskCache.first_vertex(back), Vector3(1, 2, 3))


func test_a_file_without_the_metadata_still_gives_its_first_vertex() -> void:
	assert_eq(ChunkDiskCache.first_vertex(_quad()), Vector3(1, 2, 3))


func test_the_queue_serves_the_nearest_first_whatever_the_insertion_order() -> void:
	var t := PlanetTerrain.new()
	var queue: Array[Dictionary] = []
	for z in [5000.0, 100.0, 2000.0, 800.0]:
		var info := {"center": Vector3(0, 0, -z)}
		t._queue_insert(queue, info, info.center)
	var order: Array[float] = []
	while not queue.is_empty():
		order.append(-(queue.pop_back() as Dictionary).center.z)
	assert_eq(order, [100.0, 800.0, 2000.0, 5000.0])
	t.free()


func test_a_chunk_put_back_during_the_drain_waits_aside() -> void:
	# Its tiles missing, the best chunk goes back at the same priority: put straight back it would
	# be popped again and take every try of the drain.
	var t := PlanetTerrain.new()
	t._backlog_draining = true
	t._backlog_push({"key": "a", "center": Vector3(0, 0, -100)})
	assert_eq(t._mesh_task_backlog.size(), 0, "not back in the backlog during the drain")
	assert_eq(t._backlog_held.size(), 1)
	assert_true(t._backlog_keys.has("a"), "still known, so not queued twice")
	t.free()
