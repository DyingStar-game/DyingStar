extends GutTest
## UiScaleSettings: Settings > General > Interface size. Kept within 80..120 % on a 5 % grid, stored in
## the shared settings file, and put on the window it was given.

var _config : ConfigFile
var _saves : Array = []
var _window : Window


func before_each() -> void:
	_config = ConfigFile.new()
	_saves.clear()
	_window = Window.new()
	_window.visible = false
	add_child_autofree(_window)


func _settings() -> UiScaleSettings:
	return UiScaleSettings.new(_config, func() -> void: _saves.append(true), _window)


func test_nothing_stored_is_full_size() -> void:
	assert_eq(_settings().value(), 1.0, "100 % by default")


func test_a_change_is_stored_saved_and_applied() -> void:
	var settings := _settings()
	settings.set_value(0.85)
	assert_almost_eq(settings.value(), 0.85, 0.0001, "read back")
	assert_eq(_saves.size(), 1, "saved once")
	assert_almost_eq(_window.content_scale_factor, 0.85, 0.0001, "the window drawn at that size")


func test_out_of_range_or_off_grid_is_cleaned() -> void:
	assert_eq(UiScaleSettings.clean(0.3), UiScaleSettings.MIN, "not below 80 %")
	assert_eq(UiScaleSettings.clean(2.0), UiScaleSettings.MAX, "not above 120 %")
	assert_almost_eq(UiScaleSettings.clean(0.93), 0.95, 0.0001, "onto the 5 % grid")
	_config.set_value(UiScaleSettings.SECTION, UiScaleSettings.KEY, 9.0)
	assert_eq(_settings().value(), UiScaleSettings.MAX, "a hand-edited file is clamped too")
