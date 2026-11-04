extends GutTest
## The volcano's CPU savings must change nothing: the puffs skipped by VolcanoPlumeModel and the stones
## delayed by VolcanoStoneField's read budget end up exactly where the full computation puts them.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_volcano_cpu_budget.gd

const START := 5000.0


func _profile() -> VolcanoActivityProfile:
	var profile := VolcanoActivityProfile.new()
	profile.random_enabled = false
	profile.dissipation_s = 60.0
	var event := VolcanoEvent.new()
	event.start_unix = START
	event.duration_s = 90.0
	event.strength = 1.6
	profile.events.append(event)
	return profile


func _model(profile: VolcanoActivityProfile) -> VolcanoPlumeModel:
	var model := VolcanoPlumeModel.new()
	model.profile = profile
	model.configure_appearance(41, "budget")
	return model


func _assert_same_smoke(cached: VolcanoPlumeModel, t: float) -> void:
	var fresh := _model(cached.profile)
	fresh.update(t, 0)
	assert_eq(cached.active_indices, fresh.active_indices, "same live puffs at %.0f" % t)
	assert_true(cached.b == fresh.b, "same puff densities at %.0f" % t)
	for i in fresh.active_indices:
		assert_eq(cached.a[i], fresh.a[i], "same shape for puff %d at %.0f" % [i, t])


func test_silent_puffs_match_a_full_update_through_an_activity() -> void:
	var cached := _model(_profile())
	for t: float in [4990.0, 5010.0, 5050.0, 5085.0, 5120.0, 5160.0, 5300.0]:
		cached.update(t, 0)
		_assert_same_smoke(cached, t)


func test_silent_puffs_come_back_when_the_clock_jumps_back() -> void:
	var cached := _model(_profile())
	cached.update(5050.0, 0)
	assert_gt(cached.active_indices.size(), 0, "smoke during the activity")
	cached.update(5300.0, 0)
	assert_eq(cached.active_indices.size(), 0, "no smoke once dissipated")
	cached.update(5050.0, 0)
	assert_gt(cached.active_indices.size(), 0, "the same smoke again after a jump back")
	_assert_same_smoke(cached, 5050.0)


func test_a_new_profile_forgets_the_silent_puffs() -> void:
	var model := _model(_profile())
	model.update(4000.0, 0)
	assert_eq(model.active_indices.size(), 0, "nothing before the activity")
	var always := VolcanoActivityProfile.new()
	always.random_enabled = false
	always.idle_strength = 0.5
	model.profile = always
	model.update(4000.0, 0)
	assert_gt(model.active_indices.size(), 0, "the new profile smokes at once")


func _rough(x: float, z: float) -> float:
	return -80.0 + 60.0 * sin(x * 0.011) * cos(z * 0.007) - 0.02 * sqrt(x * x + z * z)


func _field() -> VolcanoStoneField:
	var field := VolcanoStoneField.new(VolcanoPlumeModel.new(), _rough)
	return autofree(field)


func test_a_budgeted_flight_lands_like_a_full_one() -> void:
	var full := _field()
	var budgeted := _field()
	var delayed := 0
	for k in 60:
		var angle := float(k) * 0.37
		var v0 := Vector3(cos(angle) * 40.0, 60.0 + float(k) * 2.0, sin(angle) * 40.0)
		var expected := full._flight_time(v0)
		budgeted._reads_left = VolcanoStoneField.MAX_READS_PER_FRAME
		var flight := budgeted._flight_time(v0)
		while flight < 0.0:
			delayed += 1
			budgeted._reads_left = VolcanoStoneField.MAX_READS_PER_FRAME
			flight = budgeted._flight_time(v0)
		assert_eq(flight, expected, "flight %d" % k)
	assert_gt(delayed, 0, "the budget was really hit")


func test_a_stone_over_budget_changes_nothing_until_its_frame() -> void:
	var model := VolcanoPlumeModel.new()
	model.profile = _profile()
	var field: VolcanoStoneField = autofree(VolcanoStoneField.new(model, _rough))
	var dt := VolcanoStoneField.PERIOD / float(VolcanoStoneField.COUNT)
	var c := floori((START + 50.0) / dt)
	field._reads_left = 0
	# The first slot of the burst that really throws a stone.
	while field._born(c, START + 50.0):
		c += 1
	var i := posmod(c, VolcanoStoneField.COUNT)
	assert_eq(field._token[i], 0, "no new flight in the slot yet")
	field._reads_left = VolcanoStoneField.NO_READ_LIMIT
	assert_true(field._born(c, START + 50.0), "born once the reads are back")
	assert_eq(field._token[i], 1, "the slot took the flight")


func test_a_late_stone_is_never_later_than_the_limit() -> void:
	var model := VolcanoPlumeModel.new()
	model.profile = _profile()
	var field: VolcanoStoneField = autofree(VolcanoStoneField.new(model, _rough))
	field.rebuild_on_jump = false
	var dt := VolcanoStoneField.PERIOD / float(VolcanoStoneField.COUNT)
	var t := START + 50.0
	field.update(t, Vector3.ZERO, Vector3.ZERO, false)
	# A long frame: three seconds of stones are due at once, every height still to read.
	t += 3.0
	field.update(t, Vector3.ZERO, Vector3.ZERO, false)
	assert_gt(field.in_flight(t), 0, "the burst throws stones")
	assert_gte(float(field._next_c) * dt, t - VolcanoStoneField.MAX_BIRTH_LAG_S - dt * 2.0, "caught up with the limit")
	assert_lt(float(field._next_c) * dt, t - VolcanoStoneField.MAX_BIRTH_LAG_S + 0.5, "and no further in that frame")
