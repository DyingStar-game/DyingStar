extends Node
## Regression against the shipped Tarsis III manifest, not synthetic volcano overrides.
## Run headless with this scene and --volcano-view.

var failures := 0


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func _ready() -> void:
	_test_activity_and_wind()
	_test_appearance()
	_test_lifecycle()
	_test_shared_rocks()
	await _test_rock_cleanup()
	var data: PlanetData = SystemScenes.root_properties("res://scenes/systems/tarsis/tarsis_3.tscn").planet_data.duplicate(true)
	data.apply_chunk_manifest()
	data.ensure_queries_loaded()
	data.warm_mountains()
	var seen := {}
	var smoking := 0
	var dormant := 0
	var heights: Array[float] = []
	var brightness: Array[float] = []
	var lifetimes: Array[float] = []
	for ipix in 12:
		for v: VolcanoRelief.Volcano in data.get_chunk_volcanoes(1, ipix):
			var key := VolcanoFeatures.key_of(v)
			if seen.has(key):
				continue
			seen[key] = true
			var root := VolcanoFeatures.build(data, v)
			if v.activity == "dormant":
				dormant += 1
				check(root == null or root.get_node_or_null("Plume") == null, key + ": dormant volcano has no plume")
			else:
				smoking += 1
				check(root != null, key + ": existing volcano creates features")
				if root != null:
					var plume := root.get_node_or_null("Plume") as VolcanoPlume
					check(plume != null, key + ": game feature factory uses new plume")
					if plume != null:
						heights.append(plume.model.ceiling_m)
						brightness.append(plume.model.ash_brightness)
						lifetimes.append(plume.model.lifetime_s)
						check(plume.volcano == v and plume.data == data, key + ": plume uses actual planet and volcano")
						check(plume.basis.y.is_equal_approx(v.c.normalized()), key + ": plume follows spherical up")
			if root != null:
				check((root.get_node_or_null("LavaLake") != null) == (v.lake and v.rc > 0.0), key + ": lake preserved")
				root.free()
	check(smoking > 0, "Tarsis III manifest contains non-dormant volcanoes")
	if not heights.is_empty():
		print(
			(
				"VOLCANO APPEARANCE: Tarsis III heights %.0f..%.0f m, smoke lifetime %.0f..%.0f s, brightness %.2f..%.2f"
				% [heights.min(), heights.max(), lifetimes.min(), lifetimes.max(), brightness.min(), brightness.max()]
			)
		)
	for shader in ["plume.gdshader", "rock.gdshader", "stones.gdshader", "trails.gdshader"]:
		check(load(VolcanoPlume.SHADER_DIR + shader) is Shader, shader + ": shader resource loads")
	print("VOLCANO TARSIS III: %d existing volcanoes, %d with plume, %d dormant, %d failures" % [seen.size(), smoking, dormant, failures])
	get_tree().quit(0 if failures == 0 else 1)


func _test_activity_and_wind() -> void:
	var profile := VolcanoActivityProfile.new()
	profile.random_enabled = false
	var event := VolcanoEvent.new()
	event.start_unix = 1800000000.0
	event.duration_s = 100.0
	event.strength = 2.5
	event.volcano_key = "target"
	profile.events.append(event)
	var temp_path := "user://volcano_profile_roundtrip_test.tres"
	check(ResourceSaver.save(profile, temp_path) == OK, "profile and event save to a resource")
	var restored := ResourceLoader.load(temp_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VolcanoActivityProfile
	check(
		restored != null and restored.events.size() == 1 and restored.events[0].start_unix == event.start_unix,
		"UTC event survives save and reload"
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
	check(is_equal_approx(profile.activity_at(event.start_unix - 1, 4, "target"), profile.idle_strength), "event does not start early")
	check(is_equal_approx(profile.activity_at(event.start_unix + 50, 4, "target"), 2.5), "scheduled event reaches its configured force")
	check(is_equal_approx(profile.activity_at(event.start_unix + 50, 4, "other"), profile.idle_strength), "event respects target volcano")
	check(is_zero_approx(profile.activity_at(event.start_unix + 100, 4, "target", true)), "dormant volcano goes quiet after event")
	check(is_equal_approx(profile.activity_at(event.start_unix + 50, 4, "target", true), 2.5), "scheduled event can wake a dormant volcano")
	event.volcano_key = ""
	check(is_equal_approx(profile.activity_at(event.start_unix + 50, 4, "other"), 2.5), "planet event targets every volcano")
	profile.events.clear()
	profile.random_enabled = true
	var other := profile.duplicate(true) as VolcanoActivityProfile
	var peaks := 0
	var differences := 0
	for t in range(1800000000, 1800003600, 5):
		var strength := profile.activity_at(t, 4, "target")
		check(strength == other.activity_at(t, 4, "target"), "same seed and UTC produce identical activity")
		check(strength >= profile.idle_strength and strength <= profile.strength_max, "random strength stays in bounds")
		if strength > 0.5:
			peaks += 1
		if strength != profile.activity_at(t, 12, "other"):
			differences += 1
	check(peaks > 0 and differences > 0, "random cycles erupt and differ across volcanoes")
	profile.duration_s = profile.interval_s
	check(not profile.validation_error().is_empty(), "reject overlapping jittered cycles")
	var model := VolcanoPlumeModel.new()
	model.sample_wind(1000, Vector2(10, 0))
	check(model.wind_displacement(1000, 100).is_equal_approx(Vector2(1000, 0)), "steady wind advects existing smoke")
	model.sample_wind(1001, Vector2(-10, 0))
	check(model.wind_displacement(1001, 100).x > 900, "wind reversal does not flip existing smoke instantly")
	for t in range(1002, 1120):
		model.sample_wind(t, Vector2(-10, 0))
	check(model.wind_displacement(1119, 10).x < 0, "new smoke follows changed wind")
	model.sample_wind(20, Vector2.ZERO)
	check(model.wind_displacement(20, 10).is_zero_approx(), "debug clock reset and calm wind are safe")
	print("VOLCANO ACTIVITY AND WIND: deterministic randomness, UTC scheduling, targets, dormant events and changing wind checked")


func _test_appearance() -> void:
	var first := VolcanoPlumeModel.new()
	first.configure_appearance(41, "volcano-a")
	var same := VolcanoPlumeModel.new()
	same.configure_appearance(41, "volcano-a")
	var other := VolcanoPlumeModel.new()
	other.configure_appearance(41, "volcano-b")
	check(
		first.ceiling_m == same.ceiling_m and first.ash_brightness == same.ash_brightness and first.lifetime_s == same.lifetime_s,
		"same volcano keeps its appearance across launches"
	)
	check(
		first.ceiling_m != other.ceiling_m and first.ash_brightness != other.ash_brightness and first.lifetime_s != other.lifetime_s,
		"different volcanoes vary even when source seeds match"
	)
	var neutral := VolcanoPlumeModel.new()
	neutral.configure_appearance(41, "volcano-a", 0.0)
	check(
		neutral.ceiling_m == 8500.0 and neutral.lifetime_s == VolcanoPlumeModel.LIFE and neutral.ash_brightness == 1.0,
		"variation slider can restore neutral dimensions and brightness"
	)
	first.sample_wind(1000, Vector2(20, 0))
	first.update(1000, 0)
	same.sample_wind(1000, Vector2(20, 0))
	same.update(1000, 0)
	check(first.a == same.a and first.b == same.b, "puff geometry and shade remain reproducible")
	for seed_value in 32:
		var model := VolcanoPlumeModel.new()
		model.configure_appearance(seed_value, str(seed_value))
		model.sample_wind(1000, Vector2(25, 0))
		model.update(1000, 0)
		for puff in model.a:
			check(is_finite(puff.x) and is_finite(puff.y) and is_finite(puff.z) and puff.w > 0.0, "varied plume geometry stays finite")
	print("VOLCANO VARIATION: stable identities, different heights/lengths/shades and finite puff geometry checked")


func _visible_smoke(model: VolcanoPlumeModel) -> Vector2:
	var count := 0.0
	var height := 0.0
	for i in model.b.size():
		if model.b[i].x > 0.001:
			count += 1.0
			height = maxf(height, model.a[i].y)
	return Vector2(count, height)


func _test_shared_rocks() -> void:
	var model := VolcanoPlumeModel.new()
	model.profile = VolcanoActivityProfile.new()
	model.profile.random_enabled = false
	var calls := [0]
	var ground := func(_x: float, _z: float) -> float:
		calls[0] += 1
		return 0.0
	var first := VolcanoStoneField.new(model, ground)
	var second := VolcanoStoneField.new(model, ground)
	first.rebuild_on_jump = false
	check(first._rock_meshes[0] == second._rock_meshes[0], "volcanoes share immutable rock meshes")
	check(first._instances.multimesh.mesh == second._instances.multimesh.mesh, "flying rock geometry is shared")
	check(first.mat != second.mat and first._tex != second._tex, "per-volcano particle state remains independent")
	first.update(1000.0, Vector3.ZERO, Vector3.ZERO, false)
	first.update(1000.2, Vector3.ZERO, Vector3.ZERO, false)
	check(calls[0] == 0 and first.in_flight(1000.2) == 0, "cold volcano does not sample terrain or emit rocks")
	check(not first._instances.visible and not first._trails.visible, "cold volcano does not draw empty rock batches")
	var source := VolcanoActivityProfile.new()
	var event := VolcanoEvent.new()
	event.start_unix = 1800000000.0
	source.events.append(event)
	var copy := VolcanoActivityProfile.new()
	copy.copy_from(source)
	source.events[0].strength = 0.25
	source.events.clear()
	check(copy.events.size() == 1 and copy.events[0].strength != 0.25, "profile copies isolate drafts and their events")
	first.free()
	second.free()
	print("VOLCANO RESOURCES: shared immutable meshes, isolated materials/profiles and no idle terrain queries checked")


func _test_rock_cleanup() -> void:
	var model := VolcanoPlumeModel.new()
	model.profile = VolcanoActivityProfile.new()
	model.profile.random_enabled = false
	var queries := [0]
	var ground := func(_x: float, _z: float) -> float:
		queries[0] += 1
		return 0.0
	var field := VolcanoStoneField.new(model, ground)
	field.rebuild_on_jump = false
	add_child(field)
	field.update(1000.0, Vector3.ZERO, Vector3.ZERO, false)
	# Oversubscribe the pool; airborne rocks cannot evict one another.
	for i in VolcanoStoneField.MAX_ROCKS + 30:
		field._spawn_rock(1000.0, Vector3(0, 10, 0), Vector3.ZERO, 1.0, i)
	check(field.props_alive() == VolcanoStoneField.MAX_ROCKS, "promoted rock count remains capped under spawn pressure")
	field._rocks[0].asleep = true
	field._rocks[0].rest_at = 1000.0
	field._spawn_rock(1000.0, Vector3(0, 10, 0), Vector3.ZERO, 1.0, 1000)
	check(field.props_alive() == VolcanoStoneField.MAX_ROCKS, "evicting an old resting rock does not grow the pool")
	field._last_t = 1301.0
	field._physics_process(0.016)
	check(field.props_alive() == VolcanoStoneField.MAX_ROCKS, "fading rocks still occupy the capped pool")
	check(queries[0] == 0, "absolute age expires moving rocks before any further terrain query")
	field._last_t += VolcanoStoneField.RETIRE_S + 0.1
	field._physics_process(0.016)
	check(field.props_alive() == 0 and not field.is_physics_processing(), "all never-resting rocks eventually despawn and stop physics")
	await get_tree().process_frame
	check(field.get_child_count() == 2, "retirement leaves only the two fixed rendering batches, with no tween backlog")
	field._last_t = 2000.0
	field._spawn_rock(2000.0, Vector3(2000, 10, 0), Vector3.ZERO, 1.0, 0)
	field._physics_process(0.016)
	check(field._rocks[0].retire_at == 2000.0, "rocks far from the camera enter retirement")
	field.suspend()
	await get_tree().process_frame
	check(field.props_alive() == 0 and not field.is_physics_processing(), "hidden fields remove their rocks and stop physics")
	field.update(3000.0, Vector3.ZERO, Vector3.ZERO, false)
	for i in VolcanoStoneField.MAX_DUST + 5:
		field._dust(Vector3.ZERO, 1.0, 20.0)
	check(field._dust_nodes.size() == VolcanoStoneField.MAX_DUST, "dust effects are independently capped")
	field._dust_nodes[0].finished.emit()
	check(field._dust_nodes.size() == VolcanoStoneField.MAX_DUST - 1, "finished dust releases its slot")
	field._heights[Vector3i.ZERO] = 0.0
	field.suspend()
	await get_tree().process_frame
	check(field._dust_nodes.is_empty() and field._heights.is_empty(), "suspension releases dust and cached terrain heights")
	check(field.get_child_count() == 2, "suspension leaves no rock or dust children behind")
	# An ordinary flight ends before its ribbon; neither is allowed to repeat after a time jump.
	field.update(4000.0, Vector3.ZERO, Vector3.ZERO, false)
	field._write(0, Vector3(100, 40, 0), 4000.0, 1.0, 8.0, 0.5, 1.0)
	field._register(0, Vector3(100, 40, 0), 4000.0, 1.0, 8.0, 4000.0)
	for i in range(1, 82):
		field.update(4000.0 + float(i) * 0.1, Vector3.ZERO, Vector3.ZERO, false)
	check(not field._instances.visible and field._trails.visible, "trail can fade after the final flying stone has landed")
	for i in range(82, 152):
		field.update(4000.0 + float(i) * 0.1, Vector3.ZERO, Vector3.ZERO, false)
	check(not field._trails.visible, "last trail batch stops after its bounded lifetime")
	check(field._img.get_pixel(0, 1).a == 0.0, "expired GPU rows are cleared instead of replaying on the modulo clock")
	field._token[2] += 1
	field._write(2, Vector3.UP * 12, 4015.2, 1.0, 1.2, 0.5, 1.0)
	field._register(2, Vector3.UP * 12, 4015.2, 1.0, 1.2, 4015.2)
	field._promote_due(4015.5, Vector3.ZERO)
	check(field.promoted_total > 0, "short flights promote in the next bucket instead of leaking past-due events")
	field._token[2] += 1
	field._write(2, Vector3.UP * 20, 4016.0, 1.0, 20.0, 0.5, 1.0)
	field._register(2, Vector3.UP * 20, 4016.0, 1.0, 20.0, 4016.0)
	field._promote_due(4024.0, Vector3.ZERO)
	check(field._img.get_pixel(2, 1).a > 0.0, "old expiration events cannot delete a replacement flight")
	field._write(1, Vector3.UP, 4015.0, 1.0, 8.0, 0.5, 1.0)
	field._register(1, Vector3.UP, 4015.0, 1.0, 8.0, 4015.0)
	field.update(5000.0, Vector3.ZERO, Vector3.ZERO, false)
	check(field._img.get_pixel(1, 1).a == 0.0 and field._buckets.is_empty(), "time jumps clear GPU slots and pending promotions")
	var instances := field._instances
	field.free()
	check(not is_instance_valid(instances), "unloading the field frees its rendering batches too")
	print("VOLCANO CLEANUP: bounded pools, hard lifetime, distance retirement, dust, suspension and time jumps checked")


func _test_lifecycle() -> void:
	var profile := VolcanoActivityProfile.new()
	profile.random_enabled = false
	profile.dissipation_s = 60.0
	var event := VolcanoEvent.new()
	event.start_unix = 10000.0
	event.duration_s = 180.0
	event.strength = 2.5
	event.ramp_up_s = 30.0
	event.ramp_down_s = 20.0
	event.eruption_enabled = false
	profile.events.append(event)
	var model := VolcanoPlumeModel.new()
	model.profile = profile
	model.update(9999.0, 0)
	check(_visible_smoke(model).x == 0.0 and model.state_label(9999) == "ETEINT", "off state has absolutely no smoke")
	model.update(10015.0, 0)
	var growing := _visible_smoke(model)
	check(growing.x > 0.0 and model.state_label(10015) == "FORMATION DU PANACHE", "new activity creates smoke progressively from the vent")
	check(model.eruption_activity(10090) == 0.0, "even a strong smoke-only episode cannot launch rocks")
	model.update(10090.0, 0)
	var full := _visible_smoke(model)
	check(full.x > growing.x and full.y > growing.y, "plume grows in height and emitted puff count instead of appearing complete")
	check(model.state_label(10090) == "PANACHE SEUL", "smoke-only episode remains distinct from eruption")
	model.update(10181.0, 0)
	check(
		model.activity(10181) == 0.0 and _visible_smoke(model).x > 0.0 and model.state_label(10181) == "DISSIPATION",
		"emission stops but existing smoke dissipates progressively"
	)
	model.update(10241.0, 0)
	check(
		_visible_smoke(model).x == 0.0 and model.state_label(10241) == "ETEINT", "smoke disappears completely after configured dissipation"
	)
	event.eruption_enabled = true
	check(
		model.eruption_activity(10015) == 0.0 and model.eruption_activity(10090) > 0.0, "eruptive episodes form smoke before throwing rocks"
	)
	profile.events.clear()
	profile.random_enabled = true
	profile.eruption_chance = 0.0
	var smoke_episodes := 0
	for t in range(1800000000, 1800003600, 5):
		if model.activity(t) > 0.1:
			smoke_episodes += 1
		check(model.eruption_activity(t) == 0.0, "zero eruption chance produces only smoke episodes")
	check(smoke_episodes > 0, "smoke-only random activity still occurs")
	profile.eruption_chance = 1.0
	var eruptive_samples := 0
	for t in range(1800000000, 1800003600, 5):
		if model.eruption_activity(t) > 0.1:
			eruptive_samples += 1
	check(eruptive_samples > 0, "full eruption chance produces eruptive episodes")
	print("VOLCANO LIFECYCLE: off, growing plume, smoke-only, eruption delay, dissipation and complete extinction checked")
