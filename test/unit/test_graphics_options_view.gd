extends GutTest
## GraphicsOptionsView: the lines built from GraphicsOptions write through RenderSettings and redraw
## from it. SettingsManager.render is swapped for a throwaway model, so nothing reaches the real
## user://settings.ini.

var _real_render : RenderSettings
var _render : RenderSettings
var _box : VBoxContainer
var _view : GraphicsOptionsView


func before_each() -> void:
	_real_render = SettingsManager.render
	_render = RenderSettings.new(ConfigFile.new(), func() -> void: pass,
		{"method": "forward_plus", "tier": GpuTier.HIGH, "adapter": "Test GPU"})
	_render.ensure_initialized(false)
	SettingsManager.render = _render
	_box = VBoxContainer.new()
	add_child_autofree(_box)
	_view = GraphicsOptionsView.new(SettingsRowFactory.new(16, 14, 120.0))
	add_child_autofree(_view)
	_view.build(_box)


func after_each() -> void:
	SettingsManager.render = _real_render


func _control(key: String) -> Control:
	for line in _box.get_children():
		if line is HBoxContainer and (line.get_child(0) as Label).text == GraphicsOptions.find(key)["label"]:
			return line.get_child(1)
	return null


func test_one_line_per_option_plus_headings_and_preset() -> void:
	var lines : int = 0
	var headings : int = 0
	for child in _box.get_children():
		if child is HBoxContainer:
			lines += 1
		elif child is Label:
			headings += 1
	assert_eq(headings, GraphicsOptions.SECTIONS.size(), "one heading per section")
	assert_eq(lines, GraphicsOptions.OPTIONS.size() + 2, "every option, plus preset and Recommended")


func test_a_toggle_writes_the_model() -> void:
	var taa : Button = _control("aa_taa")
	taa.button_pressed = true
	assert_true(_render.get_value("aa_taa"), "clicked on -> stored on")
	assert_eq(taa.text, "%%MENU_ON", "and it says so")


func test_fsr2_greys_taa_with_a_reason() -> void:
	var upscaler : OptionButton = _control("upscale_mode")
	var fsr2 : int = -1
	for i in upscaler.item_count:
		if upscaler.get_item_metadata(i) == Viewport.SCALING_3D_MODE_FSR2:
			fsr2 = i
	upscaler.select(fsr2)
	upscaler.item_selected.emit(fsr2)
	var taa : Button = _control("aa_taa")
	assert_true(taa.disabled, "TAA greyed under FSR 2.2")
	assert_ne(taa.tooltip_text, "", "with a tooltip saying why")


func test_the_preset_picker_follows_the_model() -> void:
	_render.apply_preset(GpuTier.ULTRA)
	var preset : OptionButton = _box.get_child(0).get_child(1)
	assert_eq(preset.selected, GraphicsOptions.PRESETS.find(GpuTier.ULTRA), "shows Ultra")
	_render.set_value("debanding", false)
	assert_eq(preset.selected, GraphicsOptions.PRESETS.size(), "shows Custom once an option moves")


func test_a_slider_shows_its_unit() -> void:
	_render.set_value("render_scale", 0.75)
	var bar : HSlider = _control("render_scale")
	assert_almost_eq(bar.value, 0.75, 0.001, "slider follows the model")
	assert_eq((bar.get_parent().get_child(2) as Label).text, "75 %", "as a percentage")
