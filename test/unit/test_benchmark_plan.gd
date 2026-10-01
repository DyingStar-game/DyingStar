extends GutTest
## BenchmarkPlan: which steps the benchmark takes for a given set of settings, and how long it lasts.


func _effective(preset_name: String) -> Dictionary:
	var render := RenderSettings.new(ConfigFile.new(), func() -> void: pass, {"method": "forward_plus"})
	render.ensure_initialized(false)
	render.apply_preset(preset_name)
	var out : Dictionary = {}
	for option in GraphicsOptions.OPTIONS:
		out[option["key"]] = render.effective(option["key"])
	return out


func _ids(plan: Array[Dictionary]) -> Array:
	return plan.map(func(step: Dictionary) -> String: return step["id"])


func test_ultra_measures_every_costly_effect_between_two_baselines() -> void:
	var plan := BenchmarkPlan.steps(_effective(GpuTier.ULTRA), PackedStringArray(), true)
	assert_eq(_ids(plan), [
		"baseline", "render_scale", "upscaler", "atmosphere_quality", "aerial", "shadows", "shadow_sun_res",
		"shadow_filter", "ssao", "ssil", "ssr", "glow", "anisotropic", "ground_quality", "mesh_lod",
		"foliage_distance", "structures_distance", "terrain_distance", "baseline_end",
	], "Ultra, in run order")


func test_what_is_already_off_is_not_measured() -> void:
	var effective := _effective(GpuTier.ULTRA)
	effective["shadows"] = false
	effective["ssao"] = 0
	var ids := _ids(BenchmarkPlan.steps(effective, PackedStringArray(), true))
	assert_does_not_have(ids, "shadows", "shadows already off")
	assert_does_not_have(ids, "shadow_sun_res", "nor their resolution")
	assert_does_not_have(ids, "ssao", "SSAO already off")


func test_an_option_owned_by_client_ini_is_skipped() -> void:
	var ids := _ids(BenchmarkPlan.steps(_effective(GpuTier.ULTRA), PackedStringArray(["atmosphere_quality"]), true))
	assert_does_not_have(ids, "atmosphere_quality", "changing it would change nothing")


func test_the_haze_step_needs_the_haze_on() -> void:
	assert_does_not_have(_ids(BenchmarkPlan.steps(_effective(GpuTier.ULTRA), PackedStringArray(), false)), "aerial",
		"already off (Alt+I)")
	for step in BenchmarkPlan.steps(_effective(GpuTier.ULTRA), PackedStringArray(), true):
		assert_eq(step["aerial"], step["id"] != "aerial", "%s: the haze is on except in its own step" % step["id"])


func test_the_upscaler_step_pins_msaa_and_taa_off() -> void:
	for step in BenchmarkPlan.steps(_effective(GpuTier.ULTRA), PackedStringArray(), true):
		if step["id"] == "upscaler":
			assert_eq(step["set"]["aa_msaa"], Viewport.MSAA_DISABLED, "MSAA stays off")
			assert_false(step["set"]["aa_taa"], "TAA stays off")
			return
	fail_test("no upscaler step under FSR 2.2")


func test_every_target_is_a_real_value_of_its_option() -> void:
	for candidate in BenchmarkPlan.CANDIDATES:
		for key in candidate["set"]:
			var option := GraphicsOptions.find(key)
			assert_false(option.is_empty(), "%s: %s is an option" % [candidate["id"], key])


func test_low_measures_less_and_a_run_stays_within_three_minutes() -> void:
	var ultra := BenchmarkPlan.steps(_effective(GpuTier.ULTRA), PackedStringArray(), true)
	var low := BenchmarkPlan.steps(_effective(GpuTier.LOW), PackedStringArray(), true)
	assert_lt(low.size(), ultra.size(), "fewer effects on Low")
	assert_lt(BenchmarkPlan.estimate_s(ultra), 180.0, "the button promises about 3 min")
	assert_eq(_ids(low)[0], "baseline", "always starts on the player's settings")
	assert_eq(_ids(low)[-1], "baseline_end", "and ends on them")
