extends GutTest
## The VR comfort settings (Settings > General, in VR only): stored in the one settings file, kept to
## what the game can play whatever a hand-edited file says, and shown as lines only in a headset.

var _config := ConfigFile.new()
var _saves: int = 0
var _settings: VrComfortSettings = null


func before_each() -> void:
	_config = ConfigFile.new()
	_saves = 0
	_settings = VrComfortSettings.new(_config, func() -> void: _saves += 1)


func test_comfortable_defaults() -> void:
	assert_true(_settings.snap_turn(), "steps: a smooth turn makes many players sick")
	assert_eq(_settings.snap_deg(), 30.0)
	assert_true(_settings.vignette())
	assert_false(_settings.left_handed())
	assert_false(_settings.walk_by_hand())
	assert_false(_settings.seated())


func test_a_change_is_saved_in_the_vr_section() -> void:
	_settings.set_value("snap_deg", 44.0)
	assert_eq(_config.get_value("vr", "snap_deg"), 45.0, "on the 15 deg grid")
	assert_eq(_saves, 1)


func test_a_hand_edited_file_never_breaks_the_game() -> void:
	_config.set_value("vr", "turn", "sideways")
	_config.set_value("vr", "smooth_deg_s", 9999)
	_config.set_value("vr", "vignette", "yes")
	assert_true(_settings.snap_turn())
	assert_eq(_settings.smooth_deg_s(), VrComfortSettings.SMOOTH_MAX)
	assert_true(_settings.vignette(), "not a bool: the default")


func test_the_page_lines_write_their_setting() -> void:
	var rows := VBoxContainer.new()
	add_child_autofree(rows)
	VrComfortRows.build(rows, _settings)
	for key: String in VrComfortRows.ORDER:
		assert_not_null(rows.get_node_or_null("Vr_" + key), "a line for " + key)
	var hand: OptionButton = rows.get_node("Vr_hand").get_child(1)
	hand.select(1)
	hand.item_selected.emit(1)
	assert_true(_settings.left_handed())
	var seated: Button = rows.get_node("Vr_seated").get_child(1)
	seated.button_pressed = true
	assert_true(_settings.seated())


func test_a_flat_screen_shows_no_vr_lines() -> void:
	assert_false(XRMode.is_active(), "the tests run without --xr-mode on")
	var page: Control = load("res://ui/settings_page/general_page/general_settings_page.tscn").instantiate()
	add_child_autofree(page)
	assert_null(page.find_child("Vr_turn", true, false))
