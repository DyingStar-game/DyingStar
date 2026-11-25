extends GutTest
## The quakes of strong eruptions and the reach of quakes and shock waves (VolcanoSound): drawn from the
## eruption's window and the volcano's seed alone, so every player feels them at the same moment.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_volcano_quakes.gd

const REPEAT_S := 90.0
const MIN_STRENGTH := 1.5
const SALT := 4242


func _window(strength: float) -> Dictionary:
	return {"start_unix": 1000.0, "length_s": 900.0, "strength": strength, "ramp_up_s": 30.0, "ramp_down_s": 60.0}


func test_falloff_full_near_weaker_far_none_beyond() -> void:
	assert_eq(VolcanoSound.falloff_share(500.0, 3000.0, 25000.0), 1.0, "full near the vent")
	assert_eq(VolcanoSound.falloff_share(3000.0, 3000.0, 25000.0), 1.0, "full up to full_m")
	var at_10 := VolcanoSound.falloff_share(10000.0, 3000.0, 25000.0)
	var at_20 := VolcanoSound.falloff_share(20000.0, 3000.0, 25000.0)
	assert_between(at_10, 0.3, 0.6, "about half at 10 km")
	assert_between(at_20, 0.02, at_10, "still felt, weaker, at 20 km")
	assert_eq(VolcanoSound.falloff_share(25000.0, 3000.0, 25000.0), 0.0, "nothing at range_m")
	assert_eq(VolcanoSound.falloff_share(40000.0, 3000.0, 25000.0), 0.0, "nothing beyond")


func test_no_quake_for_a_weak_or_no_eruption() -> void:
	for t in range(1000, 1900, 5):
		assert_eq(VolcanoSound.quake_index(_window(1.2), float(t), REPEAT_S, SALT, MIN_STRENGTH), -1,
				"a weak eruption never quakes")
	assert_eq(VolcanoSound.quake_index({}, 1500.0, REPEAT_S, SALT, MIN_STRENGTH), -1, "no eruption, no quake")
	assert_eq(VolcanoSound.quake_index(_window(3.0), 1500.0, 0.0, SALT, MIN_STRENGTH), -1, "repeat 0 = none")


func test_quakes_come_after_the_blast_and_stop_as_the_eruption_falls() -> void:
	var window := _window(3.0)
	var blast := VolcanoSound.blast_time(window)
	var end := 1000.0 + 900.0 - 60.0
	assert_eq(VolcanoSound.quake_index(window, blast, REPEAT_S, SALT, MIN_STRENGTH), -1, "none at the blast")
	assert_eq(VolcanoSound.quake_index(window, end, REPEAT_S, SALT, MIN_STRENGTH), -1, "none once it falls")
	var previous := blast
	for i in 6:
		var at := VolcanoSound.quake_time_of(window, i, REPEAT_S, SALT)
		assert_gt(at, previous, "quake %d after the one before" % i)
		previous = at
		if at < end:
			assert_eq(VolcanoSound.quake_index(window, at + 0.01, REPEAT_S, SALT, MIN_STRENGTH), i,
					"quake %d is the last one just after its time" % i)


func test_each_quake_is_felt_once_and_the_same_for_everyone() -> void:
	var window := _window(2.5)
	var felt := 0
	var last := NAN
	var times: Array[float] = []
	var t := 1000.0
	while t < 1900.0:
		var index := VolcanoSound.quake_due(window, t, last, 3.0, REPEAT_S, SALT, MIN_STRENGTH)
		if index >= 0:
			last = VolcanoSound.quake_time_of(window, index, REPEAT_S, SALT)
			times.append(last)
			felt += 1
		t += 0.1
	assert_between(felt, 6, 11, "a handful of quakes in 15 min at one every 90 s")
	var other_client := VolcanoSound.quake_time_of(window, 2, REPEAT_S, SALT)
	assert_eq(other_client, times[2], "another client draws the same moment")
	assert_eq(VolcanoSound.quake_due(window, times[0] + 5.0, NAN, 3.0, REPEAT_S, SALT, MIN_STRENGTH), -1,
			"a player arriving after the grace does not feel it")


func test_quake_length_and_envelope() -> void:
	for i in 20:
		assert_between(VolcanoSound.quake_length(i, SALT, 1.0, 2.0), 1.0, 2.0, "length within 1..2 s")
	assert_eq(VolcanoSound.quake_envelope(-0.1, 1.5), 0.0, "nothing before")
	assert_eq(VolcanoSound.quake_envelope(1.5, 1.5), 0.0, "nothing after")
	assert_almost_eq(VolcanoSound.quake_envelope(0.5, 1.5), 1.0, 0.001, "full early on")
	assert_between(VolcanoSound.quake_envelope(1.2, 1.5), 0.0, 0.9, "dying at the end")


func test_takes_are_drawn_the_same_on_every_client() -> void:
	var takes: Array = [AudioStreamGenerator.new(), AudioStreamGenerator.new(), AudioStreamGenerator.new()]
	var seen := {}
	for i in 40:
		var take := VolcanoSound.pick_take(takes, i, SALT, 824)
		assert_true(takes.has(take), "a take of the list")
		assert_eq(take, VolcanoSound.pick_take(takes, i, SALT, 824), "same draw for the same event")
		seen[take] = true
	assert_eq(seen.size(), takes.size(), "every take comes up")
	assert_null(VolcanoSound.pick_take([], 3, SALT, 824), "no take, no sound")


func test_near_explosion_fades_into_the_far_shock_wave() -> void:
	assert_eq(VolcanoSound.wave_share(2000.0, 5000.0, 12000.0), 0.0, "near: the explosion alone")
	assert_eq(VolcanoSound.wave_share(15000.0, 5000.0, 12000.0), 1.0, "far: the shock wave alone")
	var mid := VolcanoSound.wave_share(8500.0, 5000.0, 12000.0)
	assert_almost_eq(mid, 0.5, 0.01, "half way between")
	var power := pow(cos(mid * PI * 0.5), 2.0) + pow(sin(mid * PI * 0.5), 2.0)
	assert_almost_eq(power, 1.0, 0.001, "equal power through the fade")


func test_shock_wave_sweeps_then_dies() -> void:
	var blur: GDScript = load("res://scenes/audio/volcano/volcano_shock_blur.gd")
	assert_eq(blur.wave_envelope(-0.1, 0.35).y, 0.0, "nothing before the wave")
	assert_eq(blur.wave_envelope(0.0, 0.35).y, 0.0, "it rises, never pops")
	var peak := 0.0
	var last_progress := -1.0
	for i in 35:
		var env: Vector2 = blur.wave_envelope(i * 0.01, 0.35)
		assert_gt(env.x, last_progress, "the ring always moves on")
		last_progress = env.x
		peak = maxf(peak, env.y)
	assert_between(peak, 0.5, 1.0, "a clear crest")
	assert_eq(blur.wave_envelope(0.35, 0.35).y, 0.0, "gone after its length")
	assert_eq(blur.wave_envelope(2.0, 0.35).y, 0.0, "nothing long after")


func test_shock_wave_weakens_with_distance_and_stops_at_15_km() -> void:
	var near := VolcanoSound.falloff_share(1500.0, 2000.0, 15000.0)
	var mid := VolcanoSound.falloff_share(8000.0, 2000.0, 15000.0)
	assert_eq(near, 1.0, "full near the volcano")
	assert_between(mid, 0.05, 0.6, "weaker at 8 km")
	assert_eq(VolcanoSound.falloff_share(15000.0, 2000.0, 15000.0), 0.0, "none from 15 km")
