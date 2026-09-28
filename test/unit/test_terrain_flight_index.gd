extends GutTest
## PlanetTerrain._pipeline_tree_index must answer exactly what the per-key
## _has_pending_replacement / _has_pending_coarser answered (the stale-chunk
## pass used them; walking the whole pipeline per key cost 200-440 ms a pass),
## on a random pipeline spread over the four queues.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_terrain_flight_index.gd


func _info(ns: int, ip: int) -> Dictionary:
	return {"nside": ns, "ipix": ip, "key": "hp_n%d_p%d" % [ns, ip]}


func test_index_answers_like_the_pipeline_walks() -> void:
	var t := PlanetTerrain.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	# A pipeline around one base pixel, all four queues, levels 4..1024.
	var base := 5
	var pick := func() -> Array:
		var lvl := rng.randi_range(2, 10)
		var ns := 1 << lvl
		var ip := base
		for _k in lvl:
			ip = (ip << 2) | rng.randi_range(0, 3)
		return [ns, ip]
	for i in 60:
		var c: Array = pick.call()
		match i % 4:
			0: t._mesh_tasks["m%d" % i] = {"info": _info(c[0], c[1])}
			1: t._mesh_task_backlog.append(_info(c[0], c[1]))
			2: t._assemble_queue.append({"info": _info(c[0], c[1])})
			3: t._recipe_waiters["e%d" % (i % 3)] = {"c%d" % i: _info(c[0], c[1])}
	var idx := t._pipeline_tree_index()
	var mismatches := 0
	var hits_rep := 0
	var hits_coarse := 0
	for i in 3000:
		var c: Array = pick.call()
		var key := "hp_n%d_p%d" % [c[0], c[1]]
		var rep_old := t._has_pending_replacement(key)
		var coarse_old := t._has_pending_coarser(key)
		var rep_new: bool = (idx[0] as Dictionary).has(PlanetTerrain._flight_id(c[0], c[1]))
		var coarse_new := PlanetTerrain._flight_has_ancestor(idx[1], c[0], c[1])
		if rep_old != rep_new or coarse_old != coarse_new:
			mismatches += 1
		hits_rep += int(rep_old)
		hits_coarse += int(coarse_old)
	t.free()
	assert_gt(hits_rep, 100, "the draw hits pending replacements")
	assert_gt(hits_coarse, 100, "and pending coarser chunks")
	assert_eq(mismatches, 0)
