extends GutTest
## PlanetTerrain._admit_pending hands the LOD update's chunks over a little every frame: the best first,
## none already served, and a chunk waiting for it still counts as coming, so the ground it replaces
## stays on screen. A cache read that came back for a chunk no longer wanted is dropped unassembled.


class RecordingTerrain:
	extends PlanetTerrain
	var handed: Array[Dictionary] = []

	func _try_create_or_defer(info: Dictionary) -> void:
		handed.append(info)


var _t: RecordingTerrain


func before_each() -> void:
	_t = RecordingTerrain.new()
	_t.planet_data = PlanetData.new()
	_t.planet_data.max_quadtree_depth = 8


func after_each() -> void:
	_t.free()


func _chunk(nside: int, ipix: int, lod: int = 0, stitch: int = 0) -> Dictionary:
	var info := {"key": "hp_n%d_p%d" % [nside, ipix], "nside": nside, "ipix": ipix, "lod": lod,
		"center": Vector3.ZERO}
	if stitch != 0:
		info["stitch"] = stitch
	return info


func _want(info: Dictionary) -> void:
	_t._desired_cache[info.key] = info
	_t._admit_queue.append(info.key)


func _handed_keys() -> Array[String]:
	var keys: Array[String] = []
	for info: Dictionary in _t.handed:
		keys.append(String(info.key))
	return keys


func test_the_best_is_served_first_and_the_queue_drains() -> void:
	_want(_chunk(4, 1))  # worst first: the queue is served from its end
	_want(_chunk(4, 2))
	_t._admit_pending(1000.0)
	assert_eq(_handed_keys(), ["hp_n4_p2", "hp_n4_p1"] as Array[String])
	assert_true(_t._admit_queue.is_empty())


func test_a_spent_budget_still_hands_one_over_and_keeps_the_rest() -> void:
	for i in 50:
		_want(_chunk(4, i))
	_t._admit_pending(0.0001)
	assert_gte(_t.handed.size(), 1, "a frame always makes progress")
	assert_lt(_t.handed.size(), 50, "the budget stops it")
	assert_eq(_t.handed.size() + _t._admit_queue.size(), 50, "nothing lost")


func test_what_is_no_longer_wanted_or_already_served_is_skipped() -> void:
	var gone := _chunk(4, 1)
	_want(gone)
	_t._desired_cache.erase(gone.key)
	var reading := _chunk(4, 2)
	_want(reading)
	_t._cache_loads[reading.key] = {"info": reading, "path": ""}
	var building := _chunk(4, 3)
	_want(building)
	_t._mesh_tasks[building.key] = {"info": building}
	var waiting := _chunk(4, 4)
	_want(waiting)
	_t._backlog_keys[waiting.key] = true
	var on_screen := _chunk(4, 5)
	_want(on_screen)
	_t._active_chunks[on_screen.key] = on_screen.duplicate()
	_t._admit_pending()
	assert_eq(_t.handed.size(), 0)


func test_another_quality_is_a_swap_and_a_new_chunk_is_not() -> void:
	var new_chunk := _chunk(4, 1)
	_want(new_chunk)
	var other_lod := _chunk(4, 2, 1)
	_want(other_lod)
	_t._active_chunks[other_lod.key] = _chunk(4, 2, 0)
	var other_seam := _chunk(4, 3, 0, PlanetChunk.STITCH_LEFT)
	_want(other_seam)
	_t._active_chunks[other_seam.key] = _chunk(4, 3, 0)
	_t._admit_pending()
	var swaps := {}
	for info: Dictionary in _t.handed:
		swaps[info.key] = info.get("_swap", false)
	assert_eq(swaps, {"hp_n4_p1": false, "hp_n4_p2": true, "hp_n4_p3": true})
	assert_false(_t._desired_cache[other_lod.key].has("_swap"), "the leaf set is not written into")


func test_admission_waits_while_too_much_is_unassembled() -> void:
	_want(_chunk(4, 1))
	for i in PlanetTerrain.ADMIT_MAX_UNASSEMBLED:
		_t._cache_loads["r%d" % i] = {}
	_t._admit_pending()
	assert_eq(_t.handed.size(), 0)
	assert_eq(_t._admit_queue.size(), 1, "still queued")


func test_a_chunk_waiting_for_admission_protects_what_it_replaces() -> void:
	var fine := _chunk(8, 16)  # child of (4, 4), grandchild of (2, 1)
	_want(fine)
	var index := _t._pipeline_tree_index()
	assert_true((index[0] as Dictionary).has(PlanetTerrain._flight_id(4, 4)), "the parent stays")
	assert_true((index[0] as Dictionary).has(PlanetTerrain._flight_id(2, 1)), "and any older ancestor")
	assert_true(PlanetTerrain._flight_has_ancestor(index[1], 16, 64), "and the finer chunks under it")


func test_a_stale_read_is_dropped_but_a_built_mesh_or_the_wanted_quality_is_not() -> void:
	var wanted := _chunk(4, 1, 1)
	_t._desired_cache[wanted.key] = wanted
	var same := _chunk(4, 1, 1)
	same["_from_disk_cache"] = true
	assert_false(_t._read_went_stale(same), "still what is wanted")
	var other_lod := _chunk(4, 1, 0)
	other_lod["_from_disk_cache"] = true
	assert_true(_t._read_went_stale(other_lod), "another quality")
	var gone := _chunk(4, 2)
	gone["_from_disk_cache"] = true
	assert_true(_t._read_went_stale(gone), "no longer wanted")
	var built := _chunk(4, 2)
	assert_false(_t._read_went_stale(built), "a built mesh has a cache write to publish")


## Put a chunk on screen, as the assembly records it, with no mesh: _remove_chunk copes.
func _draw(info: Dictionary) -> void:
	_t._active_chunks[info.key] = info
	_t._count_active_descendant(int(info.nside), int(info.ipix), 1)


func test_a_coarse_chunk_goes_with_the_last_of_its_children() -> void:
	var parent := _chunk(4, 4)
	_draw(parent)
	for child in [16, 17, 18, 19]:
		var info := _chunk(8, child)
		_t._desired_cache[info.key] = info
		_draw(info)
		_t._note_replaced(info)
		if child < 19:
			# Not its last child: the parent must stay, drained or not.
			_t._drain_retired()
			assert_true(_t._active_chunks.has(parent.key), "part of its area is still uncovered")
	_t._drain_retired()
	assert_false(_t._active_chunks.has(parent.key), "all four on screen, it goes at once")
	assert_eq(_t._active_chunks.size(), 4)


func test_fine_chunks_go_as_soon_as_their_coarse_replacement_is_drawn() -> void:
	var fine := _chunk(8, 16)
	var finer := _chunk(16, 68)  # child of (8, 17)
	_draw(fine)
	_draw(finer)
	var coarse := _chunk(4, 4)
	_t._desired_cache[coarse.key] = coarse
	_draw(coarse)
	_t._note_replaced(coarse)
	_t._drain_retired()
	assert_eq(_t._active_chunks.keys(), [coarse.key])


func test_what_is_still_wanted_is_never_retired() -> void:
	var parent := _chunk(4, 4)
	_t._desired_cache[parent.key] = parent
	_draw(parent)
	var child := _chunk(8, 16)
	_t._desired_cache[child.key] = child
	_draw(child)
	_t._note_replaced(child)
	_t._note_replaced(parent)
	_t._drain_retired()
	assert_eq(_t._active_chunks.size(), 2)


func test_ready_needs_every_wanted_chunk_on_screen() -> void:
	assert_false(_t._desired_all_active(), "no leaf set yet")
	var a := _chunk(4, 1)
	var b := _chunk(4, 2)
	_t._desired_cache[a.key] = a
	_t._desired_cache[b.key] = b
	_t._active_chunks[a.key] = a
	assert_false(_t._desired_all_active())
	_t._active_chunks[b.key] = b
	assert_true(_t._desired_all_active())


func _backlog(info: Dictionary) -> void:
	_t._mesh_task_backlog.append(info)
	_t._backlog_keys[info.key] = true


func test_the_backlog_forgets_what_is_no_longer_wanted() -> void:
	var left_behind := _chunk(8, 1)
	var other_quality := _chunk(8, 2, 1)
	var other_stitch := _chunk(8, 3)
	var wanted_a := _chunk(8, 4)
	var wanted_b := _chunk(8, 5)
	for info: Dictionary in [wanted_a, left_behind, other_quality, other_stitch, wanted_b]:
		_backlog(info)
	var desired := {other_quality.key: _chunk(8, 2, 2), other_stitch.key: _chunk(8, 3, 0, 1),
		wanted_a.key: wanted_a, wanted_b.key: wanted_b}
	_t._prune_backlog(desired)
	assert_eq(_t._mesh_task_backlog.size(), 2)
	assert_eq(_t._mesh_task_backlog[0].key, wanted_a.key, "the order is kept")
	assert_eq(_t._mesh_task_backlog[1].key, wanted_b.key)
	assert_false(_t._backlog_keys.has(left_behind.key), "free to be admitted again")
	assert_false(_t._backlog_keys.has(other_quality.key), "free to be admitted at its new quality")
	assert_true(_t._backlog_keys.has(wanted_a.key))


func test_a_stitch_follows_the_grids_not_the_tiers() -> void:
	_t.planet_data.radius = 6356000.0
	var mine := _chunk(64, 4, 1)
	var parent := _chunk(32, 1, 2)
	assert_false(_t._stitch_meets(parent, mine), "16 quads against 8")
	_t.planet_data.far_tier_res = _t.planet_data.chunk_resolution
	assert_true(_t._stitch_meets(parent, mine), "the same grid at two tiers")


func test_a_finer_chunk_morphs_from_its_parent_only() -> void:
	_t.planet_data.lod_morph = true
	_t._last_local_cam = Vector3(0.0, 0.0, 10000.0)
	var child := _chunk(8, 5, 1)
	assert_false(_t._lod_morph_starts(child), "over nothing: no shape to start from")
	_draw(_chunk(2, 0, 2))
	assert_true(_t._lod_morph_starts(child), "an ancestor two levels up is on screen")
	_t._last_local_cam = Vector3(0.0, 0.0, 500.0)
	assert_false(_t._lod_morph_starts(child), "close to the camera, where trees and roads stand on it")
	_t._last_local_cam = Vector3(0.0, 0.0, 10000.0)
	_draw(child)
	assert_false(_t._lod_morph_starts(_chunk(8, 5, 1, 1)), "the same chunk at another quality")
	_t.planet_data.lod_morph = false
	assert_false(_t._lod_morph_starts(_chunk(8, 6, 1)), "off unless the client turns it on")


func test_an_edge_facing_a_settled_neighbour_stays_and_easing_ones_keep_step() -> void:
	var me := _chunk(8, 100, 1)
	var around: Dictionary = HEALPix.get_neighbors_nest(8, 100)
	assert_eq(_t._lod_morph_edges(me)[0], 15, "no neighbour on screen: every edge moves")
	_draw(_chunk(8, around["W"], 1))
	var easing := _chunk(8, around["N"], 1)
	_draw(easing)
	_t._morphing[easing.key] = 5
	var edges: Array = _t._lod_morph_edges(me)
	assert_eq(edges[0] & PlanetChunk.STITCH_LEFT, 0, "the settled west neighbour keeps the seam")
	assert_ne(edges[0] & PlanetChunk.STITCH_TOP, 0, "the easing north one moves with it")
	assert_eq(edges[1], 5, "in step with it")
