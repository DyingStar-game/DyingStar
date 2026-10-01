extends GutTest
## RenderSettings + RenderApplier: the graphics options. What is stored, what applies, which preset it
## reads as, what an old settings file turns into — and that the engine receives the effective value.

const FORWARD_PLUS_CAPS : Dictionary = {"method": "forward_plus", "tier": GpuTier.HIGH, "adapter": "Test GPU"}

var _config : ConfigFile
var _saves : int = 0


func before_each() -> void:
	_config = ConfigFile.new()
	_saves = 0


func _settings(caps: Dictionary = FORWARD_PLUS_CAPS) -> RenderSettings:
	var s := RenderSettings.new(_config, func() -> void: _saves += 1, caps)
	s.ensure_initialized(false)
	return s


func test_the_table_is_consistent() -> void:
	for option in GraphicsOptions.OPTIONS:
		var key : String = option["key"]
		assert_eq(option["presets"].size(), GraphicsOptions.PRESETS.size(), "%s has one value per preset" % key)
		assert_has(GraphicsOptions.SECTIONS, option["section"], "%s is under a known heading" % key)
		assert_true(str(option.get("help", "")).begins_with("%%MENU_GFX_HELP_"), "%s explains itself on hover" % key)
		var values : Array = [option["default"]] + option["presets"]
		for value in values:
			match option["kind"]:
				GraphicsOptions.TOGGLE:
					assert_eq(typeof(value), TYPE_BOOL, "%s: toggle values are bools" % key)
				GraphicsOptions.CHOICE:
					var known : bool = false
					for choice in option["choices"]:
						known = known or GraphicsOptions.same(choice[0], value)
					assert_true(known, "%s: %s is one of its choices" % [key, value])
				GraphicsOptions.SLIDER:
					assert_between(float(value), float(option["min"]), float(option["max"]), "%s in range" % key)
		if option.has("blocked_by"):
			assert_false(GraphicsOptions.find(option["blocked_by"]["key"]).is_empty(), "%s blocked by a real option" % key)


func test_a_preset_writes_every_option_with_one_save() -> void:
	var s := _settings()
	s.apply_preset(GpuTier.LOW)
	assert_eq(_saves, 1, "one save for the whole preset")
	assert_eq(s.preset(), GpuTier.LOW, "reads back as that preset")
	for option in GraphicsOptions.OPTIONS:
		assert_true(_config.has_section_key(GraphicsOptions.SECTION, option["key"]), "%s written" % option["key"])


func test_changing_one_option_reads_as_custom_until_it_is_put_back() -> void:
	var s := _settings()
	s.apply_preset(GpuTier.MEDIUM)
	s.set_value("debanding", false)
	assert_eq(s.preset(), GraphicsOptions.CUSTOM, "one change away from a preset is custom")
	s.set_value("debanding", true)
	assert_eq(s.preset(), GpuTier.MEDIUM, "put back, it is the preset again")


func test_an_old_settings_file_keeps_its_values_and_gains_nothing() -> void:
	_config.set_value("video", "shadows", false)
	_config.set_value("video", "shadow_distance", 120.0)
	var s := _settings()
	assert_false(s.get_value("shadows"), "the old shadows choice survives")
	assert_almost_eq(float(s.get_value("shadow_distance")), 120.0, 0.001, "the old distance survives")
	assert_eq(_config.get_section_keys("video").size(), 2, "no key was added behind the player's back")
	assert_eq(_saves, 0, "nothing was saved")
	assert_eq(s.get_value("aa_msaa"), Viewport.MSAA_DISABLED, "a missing key reads as today's look")
	assert_eq(s.preset(), GraphicsOptions.CUSTOM, "an old file is not mistaken for a preset")


func test_the_first_launch_starts_on_the_detected_preset() -> void:
	var s := RenderSettings.new(_config, func() -> void: _saves += 1,
		{"method": "forward_plus", "tier": GpuTier.ULTRA})
	s.ensure_initialized(true)
	assert_eq(s.preset(), GpuTier.ULTRA, "first launch = the GPU's tier")


func test_garbage_in_the_file_reads_as_the_default() -> void:
	_config.set_value("video", "aa_msaa", "banana")
	_config.set_value("video", "render_scale", 3.0)
	_config.set_value("video", "aa_taa", 7)
	var s := _settings()
	assert_eq(s.get_value("aa_msaa"), Viewport.MSAA_DISABLED, "unknown choice -> default")
	assert_almost_eq(float(s.get_value("render_scale")), 1.0, 0.001, "out of range -> clamped")
	assert_eq(s.get_value("aa_taa"), false, "not a bool -> default")


func test_fsr2_rules_out_taa_and_msaa_without_forgetting_them() -> void:
	var s := _settings()
	s.set_value("aa_taa", true)
	s.set_value("aa_msaa", Viewport.MSAA_4X)
	s.set_value("upscale_mode", Viewport.SCALING_3D_MODE_FSR2)
	assert_false(s.effective("aa_taa"), "TAA forced off under FSR 2.2")
	assert_eq(s.effective("aa_msaa"), Viewport.MSAA_DISABLED, "MSAA forced off under FSR 2.2")
	assert_eq(s.availability("aa_taa"), "%%MENU_GFX_WHY_FSR2_TAA", "the tooltip says why")
	assert_eq(s.availability("aa_msaa"), "%%MENU_GFX_WHY_FSR2_MSAA", "the tooltip says why")
	s.set_value("upscale_mode", Viewport.SCALING_3D_MODE_BILINEAR)
	assert_true(s.effective("aa_taa"), "the stored TAA comes back")
	assert_eq(s.effective("aa_msaa"), Viewport.MSAA_4X, "the stored MSAA comes back")
	assert_eq(s.availability("fsr_sharpness"), "%%MENU_GFX_WHY_NO_FSR", "sharpness greyed without FSR")


func test_shadows_off_greys_the_sun_options_but_not_the_lamps() -> void:
	var s := _settings()
	s.set_value("shadows", false)
	assert_eq(s.availability("shadow_distance"), "%%MENU_GFX_WHY_SHADOWS_OFF", "distance greyed")
	assert_eq(s.availability("shadow_sun_res"), "%%MENU_GFX_WHY_SHADOWS_OFF", "sun resolution greyed")
	assert_eq(s.availability("shadow_light_res"), "", "lamps and torch keep their shadows")


func test_the_renderer_decides_what_is_offered() -> void:
	var mobile := _settings({"method": "mobile"})
	for key in ["aa_taa", "ssao", "ssil", "ssr"]:
		assert_eq(mobile.availability(key), GraphicsOptions.WHY_RENDERER, "%s needs Forward+" % key)
	assert_true(mobile.choice_available("upscale_mode", Viewport.SCALING_3D_MODE_FSR), "FSR 1 runs on Mobile")
	assert_false(mobile.choice_available("upscale_mode", Viewport.SCALING_3D_MODE_FSR2), "FSR 2.2 does not")
	var compat := _settings({"method": "gl_compatibility"})
	assert_eq(compat.availability("ssao"), "", "SSAO runs on Compatibility")
	assert_false(compat.choice_available("upscale_mode", Viewport.SCALING_3D_MODE_FSR), "FSR 1 does not")
	compat.set_value("upscale_mode", Viewport.SCALING_3D_MODE_FSR)
	assert_eq(compat.effective("upscale_mode"), Viewport.SCALING_3D_MODE_BILINEAR, "falls back to bilinear")


func test_a_client_ini_override_greys_the_option() -> void:
	var s := _settings({"method": "forward_plus", "overridden": PackedStringArray(["ground_quality"])})
	assert_true(s.is_overridden("ground_quality"), "client.ini owns it")
	assert_eq(s.availability("ground_quality"), GraphicsOptions.WHY_CLIENT_INI, "and the tooltip says so")


func test_changed_lists_only_what_moved() -> void:
	var s := _settings()
	var seen : Array = []
	s.changed.connect(func(keys: PackedStringArray) -> void: seen.append(keys))
	s.set_value("debanding", true)
	assert_eq(seen.back(), PackedStringArray(["debanding"]), "one option changed")
	s.set_value("debanding", true)
	assert_eq(seen.back(), PackedStringArray(), "the same value again moves nothing")
	s.set_value("upscale_mode", Viewport.SCALING_3D_MODE_FSR2)
	assert_has(seen.back(), "upscale_mode", "the upscaler moved")
	assert_does_not_have(seen.back(), "aa_taa", "TAA was already off: nothing to re-apply")


func test_the_applier_writes_the_viewport() -> void:
	var s := _settings()
	var vp := SubViewport.new()
	add_child_autofree(vp)
	var applier := RenderApplier.new(s, vp)
	s.set_value("aa_msaa", Viewport.MSAA_4X)
	s.set_value("aa_screen", Viewport.SCREEN_SPACE_AA_SMAA)
	s.set_value("render_scale", 0.75)
	s.set_value("debanding", true)
	s.set_value("anisotropic", Viewport.ANISOTROPY_8X)
	s.set_value("mesh_lod", 2.0)
	s.set_value("shadow_light_res", 1024)
	s.set_value("fsr_sharpness", 1.0)
	assert_eq(vp.msaa_3d, Viewport.MSAA_4X, "MSAA")
	assert_eq(vp.screen_space_aa, Viewport.SCREEN_SPACE_AA_SMAA, "SMAA")
	assert_almost_eq(vp.scaling_3d_scale, 0.75, 0.001, "render scale")
	assert_true(vp.use_debanding, "debanding")
	assert_eq(vp.anisotropic_filtering_level, Viewport.ANISOTROPY_8X, "anisotropic")
	assert_almost_eq(vp.mesh_lod_threshold, 2.0, 0.001, "mesh LOD")
	assert_eq(vp.positional_shadow_atlas_size, 1024, "lamp shadow atlas")
	assert_almost_eq(vp.fsr_sharpness, 0.0, 0.001, "sharpest = engine 0")
	s.set_value("upscale_mode", Viewport.SCALING_3D_MODE_FSR2)
	assert_eq(vp.msaa_3d, Viewport.MSAA_DISABLED, "FSR 2.2 turned MSAA off on the viewport")
	applier.apply_all()
	assert_eq(vp.scaling_3d_mode, Viewport.SCALING_3D_MODE_FSR2, "apply_all agrees")


func test_the_applier_writes_the_attached_environment() -> void:
	var s := _settings()
	var vp := SubViewport.new()
	add_child_autofree(vp)
	var applier := RenderApplier.new(s, vp)
	s.set_value("ssao", 3)
	var env := Environment.new()
	applier.attach_environment(env)
	assert_true(env.ssao_enabled, "SSAO applied on attach")
	assert_true(env.glow_enabled, "glow on by default, as before")
	s.set_value("ssr", 2)
	s.set_value("ssil", 1)
	s.set_value("glow", 0)
	assert_true(env.ssr_enabled, "SSR applied live")
	assert_eq(env.ssr_max_steps, 64, "SSR medium steps")
	assert_true(env.ssil_enabled, "SSIL applied live")
	assert_false(env.glow_enabled, "glow off")


func test_the_overlay_switch_persists_and_tells() -> void:
	var s := _settings()
	var told : Array = []
	s.overlay_changed.connect(func(on: bool) -> void: told.append(on))
	assert_false(s.is_overlay_enabled(), "off by default")
	s.set_overlay_enabled(true)
	assert_true(s.is_overlay_enabled(), "stored")
	assert_eq(told, [true], "told once")
	assert_eq(_saves, 1, "saved")


# ── Transient values: the benchmark's sweep ──

func test_a_transient_value_applies_without_being_stored_or_saved() -> void:
	var s := _settings()
	s.apply_preset(GpuTier.ULTRA)
	var file_before : String = _config.encode_to_text()
	var saves_before : int = _saves
	s.set_transient({"ssao": 0, "shadows": false})
	assert_eq(s.effective("ssao"), 0, "the override applies")
	assert_false(s.effective("shadows"), "both of them")
	assert_eq(s.get_value("ssao"), 3, "the stored value is untouched")
	assert_eq(s.preset(), GpuTier.ULTRA, "the page still reads as the player's preset")
	assert_eq(_saves, saves_before, "nothing saved")
	assert_eq(_config.encode_to_text(), file_before, "the file is byte for byte the same")
	assert_true(s.has_transient(), "a measurement is in progress")


func test_clearing_the_transient_values_gives_back_exactly_the_stored_ones() -> void:
	var s := _settings()
	s.apply_preset(GpuTier.HIGH)
	var before : Dictionary = {}
	for option in GraphicsOptions.OPTIONS:
		before[option["key"]] = s.effective(option["key"])
	s.set_transient({"render_scale": 0.5, "atmosphere_quality": 0, "terrain_distance": 0.5})
	s.set_transient({})
	for key in before:
		assert_true(GraphicsOptions.same(s.effective(key), before[key]), "%s is back" % key)
	assert_false(s.has_transient(), "nothing left over")


func test_an_old_file_gains_no_key_from_a_transient_value() -> void:
	var s := _settings()
	s.set_transient({"glow": 0})
	s.set_transient({})
	assert_false(_config.has_section_key(GraphicsOptions.SECTION, "glow"), "nothing written")


func test_transient_changes_report_exactly_what_moved() -> void:
	var s := _settings()
	s.apply_preset(GpuTier.ULTRA)
	var seen : Array = []
	s.changed.connect(func(keys: PackedStringArray) -> void: seen.append(keys))
	s.set_transient({"ssao": 0})
	assert_eq(seen.back(), PackedStringArray(["ssao"]), "turned down: one option moved")
	s.set_transient({"ssil": 0})
	assert_has(seen.back(), "ssao", "the previous override is lifted")
	assert_has(seen.back(), "ssil", "and the next one applies, in the same change")
	s.set_transient({})
	assert_eq(seen.back(), PackedStringArray(["ssil"]), "cleared: only what was overridden comes back")


func test_a_real_choice_during_a_measurement_wins_and_is_saved() -> void:
	var s := _settings()
	s.set_transient({"debanding": false})
	s.set_value("debanding", true)
	assert_true(s.effective("debanding"), "the player's choice applies")
	assert_eq(_config.get_value(GraphicsOptions.SECTION, "debanding"), true, "and is stored")
	assert_false(s.has_transient(), "the override for that option is gone")


func test_the_renderer_rules_still_apply_over_a_transient_value() -> void:
	var s := _settings()
	s.set_value("upscale_mode", Viewport.SCALING_3D_MODE_FSR2)
	s.set_transient({"aa_taa": true})
	assert_false(s.effective("aa_taa"), "FSR 2.2 still forces TAA off")
	s.set_transient({"shadows": false})
	assert_eq(s.availability("shadow_sun_res"), "%%MENU_GFX_WHY_SHADOWS_OFF", "rules read the effective value")


func test_the_applier_follows_a_transient_value_and_puts_it_back() -> void:
	var s := _settings()
	var vp := SubViewport.new()
	add_child_autofree(vp)
	var applier := RenderApplier.new(s, vp)  # kept: a signal does not keep a RefCounted alive
	applier.apply_all()
	assert_almost_eq(vp.scaling_3d_scale, 1.0, 0.001, "the player's scale")
	s.set_transient({"render_scale": 0.5})
	assert_almost_eq(vp.scaling_3d_scale, 0.5, 0.001, "the measurement's scale")
	s.set_transient({})
	assert_almost_eq(vp.scaling_3d_scale, 1.0, 0.001, "back to the player's")
