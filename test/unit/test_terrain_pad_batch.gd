extends GutTest
## A village's pads registered in one pass (PlanetData.register_pads, PlanetTerrain's batch) and the
## client's rebuild once a second under pads that arrive one by one: fewer rebuilds, the same ground.

const RADIUS := 6356000.0
const MPD := RADIUS * PI / 180.0
const FINEST := 1 << 14


func _data() -> PlanetData:
	var data := PlanetData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = 14
	data.relief_signature = "relief-test"
	return data


## A pad [param north_m] north and [param east_m] east of the origin, measured at [param z].
func _pad(uuid: String, east_m: float, north_m: float, half: float, z: float) -> Dictionary:
	var rec := PadBed.record(uuid, east_m / MPD, north_m / MPD, 0.0, half, half, 8.0, 0.0)
	rec["settled"] = {"z": z, "span": 0.0, "talus_m": 6.0}
	return rec


## A district whose aprons touch, of all sizes, each measured at its own altitude.
func _city() -> Array:
	var out: Array = []
	for i in 24:
		var half := 4.0 + float(i % 5) * 3.0
		out.append(_pad("prop:%d" % i, float(i % 6) * 30.0, float(i / 6) * 30.0, half, 100.0 + float(i) * 0.7))
	return out


## uuid -> [the level the ground is drawn at, its talus].
func _levels(data: PlanetData) -> Dictionary:
	var out := {}
	for rec: Dictionary in data._pads.all():
		out[rec["uuid"]] = [rec["z"], rec["talus_m"]]
	return out


func test_one_pass_gives_the_ground_of_one_by_one() -> void:
	var one_by_one := _data()
	var dirty := {}
	for rec: Dictionary in _city():
		dirty.merge(one_by_one.register_pad(rec))
	var batch := _data()
	var batch_dirty := batch.register_pads(_city())
	assert_eq(_levels(batch), _levels(one_by_one))
	assert_eq(_levels(batch).size(), 24)
	assert_eq_deep(batch_dirty, dirty)


func test_the_order_of_the_batch_does_not_matter() -> void:
	var forward := _data()
	forward.register_pads(_city())
	var backward := _data()
	var recs := _city()
	recs.reverse()
	backward.register_pads(recs)
	assert_eq(_levels(backward), _levels(forward))


func test_registering_the_same_pads_again_changes_nothing() -> void:
	var data := _data()
	data.register_pads(_city())
	var pads := data._pads
	assert_eq(data.register_pads(_city()), {}, "nothing to rebuild")
	assert_same(data._pads, pads, "and the index is not even cloned")


func test_a_pad_of_the_batch_moved_rebuilds_where_it_was() -> void:
	var data := _data()
	data.register_pad(_pad("prop:a", 0.0, 0.0, 8.0, 100.0))
	var was := data.pad_pixels(data._pads.get_rec("prop:a"))
	var dirty := data.register_pads([_pad("prop:a", 0.0, 5000.0, 8.0, 100.0), _pad("prop:b", 9000.0, 0.0, 8.0, 100.0)])
	for ip: int in was:
		assert_true(dirty.has(ip), "the ground it left")
	for ip: int in data.pad_pixels(data._pads.get_rec("prop:a")):
		assert_true(dirty.has(ip), "the ground it came to")


func test_the_same_uuid_twice_in_a_batch_keeps_the_last() -> void:
	var data := _data()
	data.register_pads([_pad("prop:a", 0.0, 0.0, 8.0, 100.0), _pad("prop:a", 0.0, 5000.0, 8.0, 100.0)])
	assert_eq(data._pads.size(), 1)
	assert_almost_eq(float(data._pads.get_rec("prop:a")["lat"]), 5000.0 / MPD, 1e-5)


func test_a_batch_re_seats_the_building_it_pulls_onto_its_level() -> void:
	var data := _data()
	var mining := _pad("prop:mining", 0.0, 0.0, 8.0, 90.0)
	data.register_pad(mining)
	data.take_caught_up_pads()
	data.register_pads([_pad("prop:depot", 0.0, 20.0, 30.0, 100.0), _pad("prop:far", 9000.0, 0.0, 8.0, 50.0)])
	assert_eq(data.take_caught_up_pads(), ["prop:mining"] as Array[String])


func test_a_pad_without_tiles_waits_and_the_others_do_not() -> void:
	var data := _data()
	data.chunk_heightmaps_dir = "res://does_not_exist_chunks"  # every tile unreadable
	var starved := PadBed.record("prop:starved", 0.0, 0.0, 0.0, 8.0, 8.0, 8.0, 0.0)
	var dirty := data.register_pads([starved, _pad("prop:settled", 9000.0, 0.0, 8.0, 100.0)])
	assert_true(data.pads_incomplete())
	assert_false(dirty.is_empty())
	assert_eq(data._pads.size(), 1)
	assert_false(data._pads.get_rec("prop:settled").is_empty())


func test_a_pad_gone_starved_leaves_the_index_and_its_ground() -> void:
	var data := _data()
	data.register_pad(_pad("prop:a", 0.0, 0.0, 8.0, 100.0))
	var was := data.pad_pixels(data._pads.get_rec("prop:a"))
	data.chunk_heightmaps_dir = "res://does_not_exist_chunks"
	var dirty := data.register_pads([PadBed.record("prop:a", 0.0, 5000.0 / MPD, 0.0, 8.0, 8.0, 8.0, 0.0)])
	assert_true(data._pads.get_rec("prop:a").is_empty())
	assert_true(data.pads_incomplete())
	for ip: int in was:
		assert_true(dirty.has(ip))


func _terrain(server: bool, initialized: bool) -> PlanetTerrain:
	var t: PlanetTerrain = autofree(PlanetTerrain.new())
	t.planet_data = _data()
	t.is_server = server
	t._initialized = initialized
	return t


func test_the_terrain_holds_a_batch_until_its_end() -> void:
	var t := _terrain(true, false)
	var held: Array = []
	t.begin_terrain_pad_batch(held)
	for rec: Dictionary in _city():
		t.register_terrain_pad(rec)
	t.end_terrain_pad_batch()
	assert_eq(held.size(), 24)
	assert_false(t.planet_data.has_pads(), "nothing registered yet")
	assert_eq(t._pad_generation, 0)
	t.register_terrain_pad(_pad("prop:other", 9000.0, 0.0, 8.0, 100.0))
	assert_eq(t._pad_generation, 1, "only the batch is held, not what comes after it")
	t.register_terrain_pads_share(held.slice(0, 10))
	t.register_terrain_pads_share(held.slice(10))
	assert_eq(t.planet_data._pads.size(), 25)
	assert_eq(t._pad_generation, 1, "registered, the chunks not rebuilt yet")
	t.terrain_pad_shares_done()
	assert_eq(t._pad_generation, 2, "one change of ground for all of them")


func test_shares_give_the_ground_of_one_pass() -> void:
	var one := _data()
	var one_dirty := one.register_pads(_city())
	var shared := _data()
	var recs := _city()
	var dirty := shared.register_pads(recs.slice(0, 7))
	dirty.merge(shared.register_pads(recs.slice(7, 19)))
	dirty.merge(shared.register_pads(recs.slice(19)))
	assert_eq(_levels(shared), _levels(one))
	assert_eq_deep(dirty, one_dirty)


func test_a_measure_taken_early_gives_the_ground_of_one_taken_at_registration() -> void:
	var late := _data()
	var bed := VillageBed.record(BED, 0.0, 0.0, 0.0, 200.0, 200.0)
	late.register_village_bed(bed)
	var rec := PadBed.record("prop:on", 0.0, 0.0, 0.0, 6.0, 6.0, 4.0, 0.0)
	late.register_pad(rec)
	var early := _data()
	early.register_village_bed(bed)
	var measured := early.pad_with_measure(rec)
	assert_true(measured.has("measured"), "taken now")
	early.register_pad(measured)
	assert_eq(_levels(early), _levels(late))
	assert_false(early._pads.get_rec("prop:on").has("measured"), "and not kept in the record")
	assert_false(early._pads.get_rec("prop:on").has("measured_on"))


func test_a_measure_taken_before_the_beds_changed_is_taken_again() -> void:
	var data := _data()
	var measured := data.pad_with_measure(PadBed.record("prop:on", 0.0, 0.0, 0.0, 6.0, 6.0, 4.0, 0.0))
	data.register_village_bed(VillageBed.record(BED, 0.0, 0.0, 0.0, 200.0, 200.0))
	measured["measured"] = {"z": 777.0, "span": 0.0, "talus_m": 4.0}
	data.register_pad(measured)
	assert_ne(float(data._pads.get_rec("prop:on")["z"]), 777.0)


func test_nothing_to_measure_for_a_pad_settled_or_unchanged() -> void:
	var data := _data()
	var settled := _pad("prop:s", 0.0, 0.0, 8.0, 100.0)
	assert_false(data.pad_with_measure(settled).has("measured"))
	var plain := PadBed.record("prop:p", 0.0, 0.0, 0.0, 6.0, 6.0, 4.0, 0.0)
	data.register_pad(plain)
	assert_false(data.pad_with_measure(plain).has("measured"))
	var notch := PadBed.notch_record("notch|prop:n", 0.0, 0.0, 0.0, 6.0, 6.0, 90.0)
	assert_false(data.pad_with_measure(notch).has("measured"))


func test_the_sampler_of_a_pad_reads_the_ground_of_all_the_beds() -> void:
	var data := _data()
	var near := VillageBed.record(BED, 0.0, 0.0, 0.0, 200.0, 200.0)
	near["z0"] = 40.0
	var other := near.duplicate()
	other["uuid"] = "village:far"
	other["lon"] = 40.0
	data._village_beds = [other, near]
	var rec := PadBed.record("prop:p", 0.002, 0.0, 0.0, 6.0, 6.0, 4.0, 0.0)
	assert_eq(VillageBed.near_pad(data._village_beds, rec, MPD), [near], "the far one is out of reach")
	var all_beds := data.pad_sampler()
	var around := data.pad_sampler(rec)
	var different := 0
	for d: Vector3 in PadBed.sample_dirs(rec, MPD) + PadBed.reach_probe_dirs(rec, MPD):
		if float(around.call(d)) != float(all_beds.call(d)):
			different += 1
	assert_eq(different, 0, "the same bits where a pad is measured")


func test_the_client_rebuilds_a_burst_once_a_second() -> void:
	var t := _terrain(false, true)
	t._pads_changed({1: true})
	assert_eq(t._pad_generation, 1, "a pad on its own goes at once")
	assert_true(t._pad_dirty_pixels.has(1))
	t._pads_changed({2: true})
	t._pads_changed({3: true})
	t._flush_pad_rebuild()
	assert_eq(t._pad_generation, 1, "the next ones wait for the period")
	assert_false(t._pad_dirty_pixels.has(2))
	t._next_pad_rebuild_ms = 0  # one second later
	t._flush_pad_rebuild()
	assert_eq(t._pad_generation, 2, "together")
	assert_true(t._pad_dirty_pixels.has(2) and t._pad_dirty_pixels.has(3))
	assert_true(t._pad_rebuild_pending.is_empty())
	t._next_pad_rebuild_ms = 0
	t._flush_pad_rebuild()
	assert_eq(t._pad_generation, 2, "nothing pending, nothing rebuilt")


func test_the_period_only_holds_on_a_running_client() -> void:
	var server := _terrain(true, false)
	server._pads_changed({1: true})
	server._pads_changed({2: true})
	assert_eq(server._pad_generation, 2, "the server's collision never waits")
	var warming := _terrain(false, false)
	warming._pads_changed({1: true})
	warming._pads_changed({2: true})
	assert_eq(warming._pad_generation, 2, "nothing is built yet: nothing to hold")
	assert_true(warming._pad_dirty_pixels.has(2))


func test_a_rebuild_touching_no_chunk_leaves_the_residency_alone() -> void:
	var t := _terrain(true, true)
	t._last_desired_keys = PackedStringArray(["hp_n8_p3"])  # wanted, not loaded: a residency pass would load it
	t._rebuild_chunks_on_tiles({1: true}, 8, "a test")
	assert_true(t._server_chunk_queue.is_empty() and t._server_chunk_tasks.is_empty())


# ── What a pad can reach ─────────────────────────────────────────────────

func test_reaching_gives_the_same_bits_as_all_the_pads() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261105
	var pads: Array = []
	for i in 60:
		var rec := PadBed.record("prop:%d" % i, rng.randf_range(-400.0, 400.0) / MPD, rng.randf_range(-400.0, 400.0) / MPD,
				rng.randf_range(-3.0, 3.0), rng.randf_range(1.0, 40.0), rng.randf_range(1.0, 40.0), rng.randf_range(2.0, 8.0), 0.0)
		rec["z"] = rng.randf_range(80.0, 120.0)
		rec["talus_m"] = rng.randf_range(0.0, 80.0)
		pads.append(PadBed.quantise(rec))
	var notch := PadBed.record("notch|prop:n", 50.0 / MPD, 50.0 / MPD, 0.5, 4.0, 9.0, 0.0, 0.0)
	notch["z"] = 70.0
	notch["talus_m"] = 0.0
	pads.append(notch)
	var moved := 0
	for i in 4000:
		var at := Vector2(rng.randf_range(-600.0, 600.0) / MPD, rng.randf_range(-600.0, 600.0) / MPD)
		var h := rng.randf_range(60.0, 140.0)
		var want := PadBed.apply(h, at, pads, MPD)
		if want != h:
			moved += 1
		assert_eq(PadBed.apply(h, at, PadBed.reaching(pads, at, MPD), MPD), want)
	assert_gt(moved, 500, "the pads do move the ground in this test")


func test_points_reached_says_what_reaching_says() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var rec := PadBed.record("prop:a", 179.999, 30.0, 0.7, 20.0, 8.0, 6.0, 0.0)
	rec["z"] = 100.0
	rec["talus_m"] = 30.0
	var points := PackedVector2Array()
	for i in 500:
		# Across the longitude wrap.
		points.append(Vector2(wrapf(179.999 + rng.randf_range(-0.002, 0.002), -180.0, 180.0), 30.0 + rng.randf_range(-0.002, 0.002)))
	var want := PackedInt32Array()
	for k in points.size():
		if not PadBed.reaching([rec], points[k], MPD).is_empty():
			want.append(k)
	assert_gt(want.size(), 0)
	assert_lt(want.size(), points.size())
	assert_eq(PadBed.points_reached(rec, points, MPD), want)


func test_the_pads_that_moved_are_told_as_they_were_and_as_they_are() -> void:
	var data := _data()
	data.register_pad(_pad("prop:a", 0.0, 0.0, 8.0, 100.0))
	assert_eq(data.take_moved_pads().size(), 1, "a new pad: as it is")
	assert_eq(data.take_moved_pads(), [], "emptied by the call")
	data.register_pad(_pad("prop:a", 0.0, 0.0, 8.0, 100.0))
	assert_eq(data.take_moved_pads(), [], "nothing moved")
	data.register_pad(_pad("prop:a", 0.0, 5000.0, 8.0, 100.0))
	var moved := data.take_moved_pads()
	assert_eq(moved.size(), 2)
	assert_ne(moved[0]["lat"], moved[1]["lat"])
	data.unregister_pad("prop:a")
	assert_eq(data.take_moved_pads().size(), 1, "a pad gone: as it was")


# ── The fences ───────────────────────────────────────────────────────────

const BED := "village:a"


## A terrain with the village bed [constant BED] and one 300 m fence along its middle, a post every
## 3 m, built on the ground; the pads [param recs] already registered.
func _fenced(recs: Array = []) -> PlanetTerrain:
	var t := _terrain(true, false)
	t.planet_data.register_village_bed(VillageBed.record(BED, 0.0, 0.0, 0.0, 200.0, 200.0))
	t.planet_data.register_pads(recs)
	var points := PackedVector2Array()
	for i in 101:
		points.append(Vector2(-150.0 + float(i) * 3.0, 0.0))
	var bed: Dictionary = t.planet_data._village_bed_of(BED)
	var fence := {"points": points, "height": 3.0, "panel_material": null, "post_material": null}
	t._village_fences[BED] = {"bed": bed, "centre": Vector2.ZERO, "fences": [fence], "pixels": {}}
	_lay(t)
	return t


## What the frames would do bit by bit.
func _lay(t: PlanetTerrain) -> void:
	t._build_village_fences(BED)
	t._step_fence_sampling(true)


## A pit [param north_m] north of the bed's centre: its floor is authored, so the ground does move (a
## pad on a village's ground is measured on it, and stays level with it whatever it says).
func _pit(uuid: String, north_m: float) -> Dictionary:
	return PadBed.notch_record(uuid, 0.0, north_m / MPD, 0.0, 12.0, 12.0, -500.0)


## A copy: a packed array is shared, and the posts sampled again would change this one as well.
func _feet(t: PlanetTerrain) -> PackedVector3Array:
	return (t._village_fences[BED]["laid"][0]["feet"] as PackedVector3Array).duplicate()


func test_a_pad_at_the_fence_gives_the_posts_of_a_full_rebuild() -> void:
	var t := _fenced()
	var before := _feet(t)
	# On the fence: only the posts within its reach go down.
	t.planet_data.register_pad(_pit("notch|prop:on", 0.0))
	var old_node: Node = t._village_fences[BED]["node"]
	t._fences_pads_moved(BED, t.planet_data.take_moved_pads())
	t._step_fence_sampling(true)
	assert_ne(t._village_fences[BED]["node"], old_node, "the node is built again")
	var partial := _feet(t)
	assert_ne(partial, before, "the ground moved under some posts")
	var same := 0
	for k in partial.size():
		if partial[k] == before[k]:
			same += 1
	assert_gt(same, 50, "and most posts were not touched")
	_lay(t)
	assert_eq(partial, _feet(t), "the very posts a full rebuild gives")


func test_a_pad_away_from_the_posts_builds_nothing() -> void:
	var t := _fenced()
	var before := _feet(t)
	var node: Node = t._village_fences[BED]["node"]
	t.planet_data.register_pad(_pit("notch|prop:far", 150.0))  # 150 m north of the fence
	var moved := t.planet_data.take_moved_pads()
	t._fences_pads_moved(BED, moved)
	t._step_fence_sampling(true)
	assert_eq(t._village_fences[BED]["node"], node, "the same node")
	assert_eq(_feet(t), before)
	_lay(t)
	assert_eq(_feet(t), before, "and a full rebuild agrees: nothing moved under the fence")


func test_a_pad_gone_gives_the_posts_back() -> void:
	var t := _fenced()
	var before := _feet(t)
	t.planet_data.register_pad(_pit("notch|prop:on", 0.0))
	t._fences_pads_moved(BED, t.planet_data.take_moved_pads())
	t._step_fence_sampling(true)
	assert_ne(_feet(t), before)
	t.planet_data.unregister_pad("notch|prop:on")
	t._fences_pads_moved(BED, t.planet_data.take_moved_pads())
	t._step_fence_sampling(true)
	assert_eq(_feet(t), before)


func test_the_fences_wait_for_the_ground_to_settle_and_tell_how_much_moved() -> void:
	var t := _fenced()
	add_child_autofree(t)
	var rec := t.planet_data.pad_pixels(PadBed.quantise(_pad("prop:on", 0.0, 0.0, 12.0, 100.0)))
	t._village_fences[BED]["pixels"] = rec
	t._fences_ground_moved(rec, [{"uuid": "prop:on"}])
	t._fences_ground_moved(rec, [{"uuid": "prop:other"}])
	assert_eq((t._fences_stale[BED]["pads"] as Array).size(), 2, "both kept for the rebuild")
	assert_false(t._fences_stale[BED]["full"])
	t._fences_ground_moved(rec)
	assert_true(t._fences_stale[BED]["full"], "the ground moved otherwise: every post in these pixels")
	t._fences_stale.clear()
	t._fences_ground_moved({123456: true}, [{"uuid": "prop:elsewhere"}])
	assert_true(t._fences_stale.is_empty(), "not under this fence")


## The server's pins as a body standing by the village [param bed_uuid] gives them.
func _pin_fences(t: PlanetTerrain, bed_uuid: String = BED) -> void:
	t._pinned_chunks[(t._village_fences[bed_uuid]["pins"] as Dictionary).keys()[0]] = 0


func test_the_fences_are_laid_a_share_a_frame_and_the_old_node_stands_until_then() -> void:
	var t := _fenced()
	var old: Node = t._village_fences[BED]["node"]
	t._build_village_fences(BED)
	_pin_fences(t)
	assert_true(t._fences_sampling.has(BED), "not done in one go")
	assert_eq(t._village_fences[BED]["node"], old)
	assert_false(old.is_queued_for_deletion())
	var steps := 0
	while t._fences_sampling.has(BED) and steps < 100000:
		t._fence_sample_frame = -1  # a new frame
		t._step_fence_sampling()
		steps += 1
	assert_false(t._fences_sampling.has(BED))
	assert_ne(t._village_fences[BED]["node"], old, "the new node")
	assert_true(old.is_queued_for_deletion())


func test_a_server_samples_no_fence_where_no_body_has_its_ground() -> void:
	var t := _fenced()
	t._build_village_fences(BED)
	var at: int = t._fences_sampling[BED]["at"]
	t._fence_sample_frame = -1
	t._step_fence_sampling()
	assert_eq(t._fences_sampling[BED]["at"], at, "nobody there: the village waits")
	_pin_fences(t)
	t._fence_sample_frame = -1
	t._fence_next_scan_ms = 0
	t._step_fence_sampling()
	assert_gt(t._fences_sampling[BED]["at"], at, "a body came: its turn")


func test_a_village_a_body_reaches_goes_before_those_queued_ahead_of_it() -> void:
	var t := _fenced()
	t._build_village_fences(BED)
	var other := "village:other"
	t._village_fences[other] = (t._village_fences[BED] as Dictionary).duplicate()
	t._village_fences[other]["pins"] = {"hp_n8192_p1": true}
	var far := t._new_fence_sampling(t._village_fences[BED]["laid"], false)
	var queue := {other: far, BED: t._fences_sampling[BED]}
	t._fences_sampling = queue
	_pin_fences(t)
	assert_eq(t._fence_village_to_sample(), BED, "behind the other in the queue, but the one with a body by it")
	t._pinned_chunks.clear()
	assert_eq(t._fence_village_to_sample(), BED, "started: finished, even if the body drove away")


func test_registering_a_village_again_does_not_start_its_fences_over() -> void:
	var t := _fenced()
	var job: Dictionary = t._village_fences[BED]
	(job["node"] as Node).free()
	job.erase("node")
	t._build_village_fences(BED)
	var sampling: Dictionary = t._fences_sampling[BED]
	sampling["at"] = 7
	t._lay_village_fences(job["bed"], job["centre"], job["fences"])
	assert_eq(t._fences_sampling[BED]["at"], 7, "the same bed: the share goes on where it was")


func test_the_state_of_the_fences_names_the_one_by_a_body() -> void:
	var t := _fenced()
	assert_string_contains(t.fence_state_report(), "near: none, awake: none")
	_pin_fences(t)
	assert_string_contains(t.fence_state_report(), "1 village(s), 1 laid")
	assert_string_contains(t.fence_state_report(), "node=true")


func test_an_awake_village_goes_first_with_no_pin_at_all() -> void:
	var t := _fenced()
	t._build_village_fences(BED)
	t.want_village_fences(BED.trim_prefix("village:"))
	assert_true(t._pinned_chunks.is_empty())
	assert_eq(t._fence_village_to_sample(), BED)


func test_an_awake_village_nobody_registered_shows_in_the_state() -> void:
	var t := _fenced()
	_pin_fences(t)
	t.want_village_fences("missing")
	assert_string_contains(t.fence_state_report(), "missing(job=false bed=false node=false")


func test_a_client_samples_its_villages_in_order_without_pins() -> void:
	var t := _fenced()
	t.is_server = false
	t._build_village_fences(BED)
	var at: int = t._fences_sampling[BED]["at"]
	t._fence_sample_frame = -1
	t._step_fence_sampling()
	assert_gt(t._fences_sampling[BED]["at"], at)


func test_a_fence_share_runs_once_a_frame() -> void:
	var t := _fenced()
	t._build_village_fences(BED)
	_pin_fences(t)
	t._fence_sample_frame = Engine.get_process_frames()
	var at: int = t._fences_sampling[BED]["at"]
	t._step_fence_sampling()
	assert_eq(t._fences_sampling[BED]["at"], at, "this frame had its share")


func test_pads_moving_while_sampling_are_not_lost() -> void:
	var t := _fenced()
	t.planet_data.register_pad(_pit("notch|prop:on", 0.0))
	t._fences_pads_moved(BED, t.planet_data.take_moved_pads())
	t.planet_data.register_pad(_pit("notch|prop:on2", 60.0))
	t._fences_pads_moved(BED, t.planet_data.take_moved_pads())
	t._step_fence_sampling(true)
	var partial := _feet(t)
	_lay(t)
	assert_eq(partial, _feet(t), "the posts of a full rebuild")


func test_memoised_surface_reads_give_the_same_bits() -> void:
	var t := _fenced(_city())
	var memo := {}
	var different := 0
	for i in 300:
		var d := HEALPix.lonlat2vec(float(i - 150) * 0.00002, float((i * 7) % 300 - 150) * 0.00002)
		if t.planet_data.carved_surface_dist(d, memo) != t.planet_data.carved_surface_dist(d):
			different += 1
	assert_eq(different, 0)
	assert_false(memo.is_empty())


func test_a_server_fence_has_its_collision_and_no_mesh() -> void:
	var t := _fenced()
	var node: Node = t._village_fences[BED]["node"]
	assert_eq(node.find_children("*", "MeshInstance3D", true, false).size(), 0)
	assert_gt(node.find_children("*", "CollisionShape3D", true, false).size(), 0)


func test_a_fence_is_left_open_where_a_road_crosses_and_told_post_by_post() -> void:
	var t := _fenced()
	var road_at := LayoutRoads.FEATURE_ID_BASE
	var cl := PackedVector2Array([Vector2(0.0, -0.002), Vector2(0.0, 0.002)])
	var cum := PackedFloat64Array([0.0, 0.004 * t.planet_data.radius * PI / 180.0])
	t.planet_data.register_village_roads(BED, [{"road_type": "road", "width": 10.0, "centerline": cl, "_cum_lengths": cum,
			"village": true, "bed": BED, "feature_id": road_at, "_sink_m": 0.0}])
	t._build_village_fences(BED)
	var s: Dictionary = t._fences_sampling[BED]
	var open: Array = s["laid"][0]["open"]
	assert_eq(open.count(true), 0, "nothing told yet")
	t._step_fence_sampling(true)
	var laid_open: Array = t._village_fences[BED]["laid"][0]["open"]
	assert_gt(laid_open.count(true), 0, "the road crosses the fence: some panels open")
	assert_lt(laid_open.count(true), laid_open.size() / 2, "and only there")
