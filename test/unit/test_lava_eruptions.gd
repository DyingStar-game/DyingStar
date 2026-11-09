extends GutTest
## Volcano eruptions driving the simulated lava: the 40-minute eruption schedule (VolcanoActivityProfile),
## the integer eruption plan the authority derives its crater commands from (LavaPlanetPatch), the LavaFlow
## prop's grid and summary codecs (LavaSummary), and the lava runtime driving a patch on the shared clock.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_lava_eruptions.gd

const Builder = preload("res://scenes/planet/lava/lava_planet_patch.gd")
const Core = preload("res://scenes/planet/lava/lava_fixed_core.gd")
const Runtime = preload("res://scenes/planet/lava/lava_planet_runtime.gd")
const Summary = preload("res://scenes/planet/lava/lava_summary.gd")
const SummaryView = preload("res://scenes/planet/lava/lava_summary_view.gd")
const SEED := 1234567
const KEY := "test@1,2"


## Every random slot of [param profile] over [param count] periods: [start, length, eruptive].
func _slots(profile: VolcanoActivityProfile, count: int) -> Array:
	var period := profile.period_s()
	var offset := VolcanoRandom.hash01(SEED, profile.seed + 301) * period
	var out: Array = []
	for slot in count:
		var s := profile._slot(slot, SEED, period, offset)
		out.append([float(s.start), float(s.length), bool(s.eruptive)])
	return out


func test_eruptions_last_40_minutes_and_smoke_alone_90_seconds() -> void:
	var profile := VolcanoActivityProfile.new()
	var eruptions := 0
	for s: Array in _slots(profile, 400):
		assert_eq(s[1], 2400.0 if s[2] else 90.0, "slot length follows its kind")
		eruptions += int(s[2])
	assert_between(eruptions, 180, 260, "about 55 % of the slots are eruptions")


func test_slots_never_overlap_and_keep_ten_minutes_of_calm_on_average() -> void:
	var profile := VolcanoActivityProfile.new()
	var slots := _slots(profile, 400)
	var calm_sum := 0.0
	var shortest := INF
	for n in range(1, slots.size()):
		var previous: Array = slots[n - 1]
		var calm: float = slots[n][0] - (previous[0] + 2400.0)  # calm after the longest slot length
		calm_sum += calm
		shortest = minf(shortest, calm)
	assert_gte(shortest, 0.5 * 600.0 - 0.001, "at least (1 - 2 x jitter) x interval_s of calm")
	assert_almost_eq(calm_sum / (slots.size() - 1), 600.0, 30.0, "10 minutes of calm on average")


func test_eruption_window_matches_the_stones_schedule() -> void:
	var profile := VolcanoActivityProfile.new()
	var found := 0
	for s: Array in _slots(profile, 40):
		var middle: float = s[0] + s[1] * 0.5
		var window := profile.eruption_window(middle, SEED, KEY)
		if s[2]:
			found += 1
			assert_almost_eq(float(window.start_unix), float(s[0]), 0.001, "window starts with the slot")
			assert_eq(float(window.length_s), 2400.0)
			assert_gt(profile.activity_at(middle, SEED, KEY, false, true), 0.0, "stones fly mid-eruption")
		else:
			assert_true(window.is_empty(), "smoke alone has no lava")
			assert_eq(profile.activity_at(middle, SEED, KEY, false, true), 0.0)
		assert_true(profile.eruption_window(s[0] - 1.0, SEED, KEY).is_empty(), "nothing before a slot")
	assert_gt(found, 0)
	assert_true(profile.eruption_window(1000.0, SEED, KEY, true).is_empty(), "a dormant volcano never erupts")


func test_dated_eruptive_event_gives_a_window() -> void:
	var profile := VolcanoActivityProfile.new()
	profile.random_enabled = false
	var event := VolcanoEvent.new()
	event.start_unix = 5000.0
	event.duration_s = 600.0
	event.strength = 2.0
	event.volcano_key = KEY
	profile.events.append(event)
	var window := profile.eruption_window(5100.0, SEED, KEY)
	assert_eq(float(window.start_unix), 5000.0)
	assert_eq(float(window.strength), 2.0)
	assert_true(profile.eruption_window(5100.0, SEED, "other@0,0").is_empty(), "targets its volcano only")
	event.eruption_enabled = false
	assert_true(profile.eruption_window(5100.0, SEED, KEY).is_empty(), "smoke-only event: no lava")


func test_profile_validation_accepts_a_long_eruption() -> void:
	var profile := VolcanoActivityProfile.new()
	assert_eq(profile.validation_error(), "")
	profile.eruption_duration_s = 0.0
	assert_ne(profile.validation_error(), "")


func _plan(length_s: float = 2400.0, strength: float = 1.0) -> Dictionary:
	return Builder.eruption_plan({"start_unix": 1000.0, "length_s": length_s, "strength": strength},
		{"source_rate_q": 3000000})


func test_plan_volume_is_integer_and_never_zero_inside_the_eruption() -> void:
	var plan := _plan()
	assert_eq(int(plan.start_unix_ms), 1000000)
	assert_eq(int(plan.eruption_ticks), 24000)
	assert_true(Builder.valid_plan(plan))
	assert_eq(Builder.eruption_volume_q(0, plan), 0, "nothing before tick 1")
	assert_eq(Builder.eruption_volume_q(24001, plan), 0, "nothing after the eruption")
	var zero := 0
	var total := 0
	for tick in range(1, 24001):
		var v := Builder.eruption_volume_q(tick, plan)
		if v <= 0: zero += 1
		total += v
	assert_eq(zero, 0, "a gap would start the cleanup mid-eruption")
	assert_eq(Builder.eruption_volume_q(800, plan), 3000000, "full rate once ramped up, before the overflow")
	assert_eq(Builder.eruption_volume_q(10000, plan), 3000000 * Builder.TAIL_PERMILLE / 1000, "tail rate")
	gut.p("40 min at strength 1: %.1f M m3" % (total / 1e9))


func test_plan_scales_with_strength() -> void:
	assert_eq(Builder.eruption_volume_q(800, _plan(2400.0, 1.6)), 4800000)
	assert_eq(Builder.eruption_volume_q(800, _plan(2400.0, 0.0)), 1, "a zero strength still keeps the vent open")


## A small polar field: 16 sectors, 8 rings of 20 m (4 in the crater), a bowl.
func _core() -> Core:
	var core := Core.new()
	var edges := PackedInt64Array()
	for r in 9: edges.append(r * 20000)
	var terrain := PackedInt64Array()
	for r in 8:
		for x in 16:
			terrain.append(-20000 if r < 4 else 0)
	assert_true(core.configure_polar_q(16, edges, terrain))
	core.crater_rows = 4
	var rims := PackedInt64Array()
	rims.resize(16)
	rims.fill(0)  # the lip at the flanks' level, as LavaPlanetPatch samples it
	core.rim_heights_q = rims
	core.cleanup_enabled = true
	return core


func test_commands_are_bounded_by_the_room_left_in_each_cell() -> void:
	var core := _core()
	var packet := {"source_radius_mm": 70000, "source_temperature_t": 12000, "source_rate_q": 3000000}
	var plan := Builder.eruption_plan({"start_unix": 0.0, "length_s": 60.0, "strength": 4.0}, packet)
	# Fill cell 0 to the brim: an unbounded command would make inject_q refuse the whole tick.
	assert_true(core.inject_q(PackedInt64Array([0, core.capacities_q[0], 12000])))
	var commands := Builder.eruption_commands(core, packet, plan, 1)
	assert_gt(commands.size(), 0)
	for p in range(0, commands.size(), 3):
		assert_ne(commands[p], 0, "the full cell gets nothing")
		assert_lte(commands[p + 1], core.capacities_q[commands[p]] - core.volume_q[commands[p]])
	assert_true(core.advance_tick(1, commands), "the tick is accepted")


func test_grid_codec_round_trips_to_the_centimetre() -> void:
	var core := _core()
	var grid := Summary.decode_grid(Summary.encode_grid(core))
	assert_eq([grid.width, grid.height, grid.crater_rows], [16, 8, 4])
	assert_eq(grid.radial_edges_mm, core.radial_edges_mm)
	for i in core.terrain_q.size():
		assert_almost_eq(float(grid.bed[i]), core.terrain_q[i] / 1000.0, 0.0051, "ground of cell %d" % i)
	assert_true(Summary.decode_grid(PackedByteArray([1, 2, 3, 4, 5])).is_empty(), "malformed bytes are refused")


func test_summary_rebuilds_exactly_the_wet_cells() -> void:
	var core := _core()
	assert_true(core.advance_tick(1, core.disc_commands(0, 0, 50000, 400000, 12000)))
	for tick in range(2, 40):
		assert_true(core.advance_tick(tick))
	var summary := Summary.new(40.0, 2)
	summary.grow(core)
	assert_gt(summary.seeds.size(), 0, "seeds on the lava")
	var grid := Summary.decode_grid(Summary.encode_grid(core))
	var view = SummaryView.from_grid(Summary.encode_grid(core))
	var fields := Summary.reconstruct(summary.encode(core), view.positions, grid.bed)
	assert_false(fields.is_empty())
	assert_eq(int(fields.tick), 39)
	for i in core.volume_q.size():
		assert_eq(fields.wet[i] == 1, core.volume_q[i] > 0, "cell %d wet as in the simulation" % i)
		if core.volume_q[i] > 0:
			assert_gt(float(fields.depth[i]), 0.0, "a wet cell has lava")
	view.apply(fields)
	assert_eq(view.wet_indices.size(), core.wet_indices.size(), "the view shows the same cells")
	assert_true(Summary.reconstruct(PackedByteArray([9, 9, 9, 9, 9]), view.positions, grid.bed).is_empty(),
		"malformed bytes are refused")


func test_authority_runtime_encodes_a_summary_on_request() -> void:
	var plan := Builder.eruption_plan({"start_unix": 100.0, "length_s": 6.0, "strength": 1.0}, {"source_rate_q": 20000})
	var clock := [100000 + 3000]
	var runtime := _runtime(clock)
	var description := _description(plan)
	assert_true(runtime.install_patch(description))
	_drive(runtime, description.key)
	assert_eq(runtime.latest_summary(description.key), [], "nothing before it is asked")
	runtime.request_summary(description.key)
	clock[0] += 1000
	_drive(runtime, description.key)
	var latest: Array = runtime.latest_summary(description.key)
	# By the first worker job after the request, at the tick it reached (later ones go on to the clock).
	assert_between(int(latest[0]), 31, runtime.patch_tick(description.key), "encoded after the request")
	assert_gt((latest[1] as PackedByteArray).size(), 0)


func test_frame_round_trips_through_json() -> void:
	var frame := Transform3D(Basis(Vector3(0.3, 0.7, 0.2).normalized(), 0.8), Vector3(1234567.891, -2345678.5, 3456789.25))
	var back: Variant = LavaFlow.array_to_frame(JSON.parse_string(JSON.stringify(LavaFlow.frame_to_array(frame))))
	assert_not_null(back)
	assert_true((back as Transform3D).origin.is_equal_approx(frame.origin))
	assert_almost_eq((back as Transform3D).basis.determinant(), 1.0, 0.00001)
	assert_null(LavaFlow.array_to_frame([1, 2, 3]))


## A description of [method _core]'s field driven by [param plan], as the server publishes it.
func _description(plan: Dictionary) -> Dictionary:
	var core := _core()
	return {"key": "planet/" + KEY, "planet": "planet", "volcano_key": KEY, "frame": Transform3D(),
		"source_x_mm": 0, "source_z_mm": 0, "source_radius_mm": 70000, "source_temperature_t": 12000,
		"source_rate_q": 20000, "crater_rows": 4, "plan": plan, "checkpoint": core.checkpoint()}


func _runtime(clock: Array) -> Node3D:
	var data := PlanetData.new()
	data.planet_name = "planet"
	var runtime: Node3D = Runtime.new()
	runtime.setup(data, true)
	runtime.clock_ms = func() -> int: return clock[0]
	runtime.catch_up_ticks = 7
	add_child_autofree(runtime)
	return runtime


## Drives [param runtime] by hand until its patch has reached the clock.
func _drive(runtime: Node3D, key: String) -> void:
	for n in 1000:
		runtime._drive()
		runtime._wait_patch(key)
		if runtime.patch_tick(key) >= runtime.target_tick(key):
			return


func test_runtime_catches_up_to_the_clock_with_the_plan_commands() -> void:
	var plan := Builder.eruption_plan({"start_unix": 100.0, "length_s": 6.0, "strength": 1.0}, {"source_rate_q": 20000})
	var clock := [100000 + 12000]  # 12 s after the start: 120 ticks
	var runtime := _runtime(clock)
	var description := _description(plan)
	assert_true(runtime.install_patch(description))
	_drive(runtime, description.key)
	assert_eq(runtime.patch_tick(description.key), 120)
	# Reference: the same commands stepped by hand.
	var reference := _core()
	for tick in range(1, 121):
		assert_true(reference.advance_tick(tick, Builder.eruption_commands(reference, description, plan, tick)))
	assert_eq(runtime.patch_checkpoint(description.key), reference.checkpoint(), "same state as by hand")
	assert_eq(runtime.latest_digest(description.key), [100, _digest_at(description, plan, 100)])


func _digest_at(description: Dictionary, plan: Dictionary, at: int) -> String:
	var core := _core()
	for tick in range(1, at + 1):
		core.advance_tick(tick, Builder.eruption_commands(core, description, plan, tick))
	return core.state_digest()


func test_replica_stops_on_a_wrong_digest_until_a_checkpoint_repairs_it() -> void:
	var plan := Builder.eruption_plan({"start_unix": 100.0, "length_s": 6.0, "strength": 1.0}, {"source_rate_q": 20000})
	var clock := [100000 + 6000]
	var runtime := _runtime(clock)
	var description := _description(plan)
	assert_true(runtime.install_patch(description))
	runtime.expect_digest(description.key, 50, _digest_at(description, plan, 50))
	runtime.expect_digest(description.key, 100, "not the authority's state")
	clock[0] += 6000
	_drive(runtime, description.key)
	assert_true(runtime.is_diverged(description.key), "the wrong digest stops the patch")
	var stopped: int = runtime.patch_tick(description.key)
	clock[0] += 3000
	runtime._drive()
	runtime._wait_patch(description.key)
	assert_eq(runtime.patch_tick(description.key), stopped, "a diverged patch does not advance")
	assert_true(runtime.install_patch(description), "a checkpoint replaces it")
	assert_false(runtime.is_diverged(description.key))
