extends GutTest
## DevOverlay: the debug readouts in one panel on the right. The F8 capture forces the debug panels
## for ONE frame through a preview of show_debug; they must be up and filled in that very frame. The dev
## clock alert shows even with the debug panels off. Switches are previewed: nothing is saved.

var _saved_offset : float = 0.0
var _panel : OverlayPanel
var _driving : Vehicle = null
var _map : FakeMap


## The chart without its scene: open is shown, and what the overlay hands it is recorded.
class FakeMap extends StarMap:
	var inset : float = -1.0

	func _ready() -> void:
		hide()

	func debug_lines() -> PackedStringArray:
		return PackedStringArray(["22 bodies"])

	func set_right_inset(px: float) -> void:
		inset = px


func before_each() -> void:
	_saved_offset = Globals.debug_time_offset
	Globals.debug_time_offset = 0.0
	var body := Node3D.new()
	add_child_autofree(body)
	_map = FakeMap.new()
	add_child_autofree(_map)
	_panel = DevOverlay.create(body, null, func() -> Dictionary: return {}, func() -> Vehicle: return _driving,
		_map)
	add_child_autofree(_panel)
	# Start from "everything off", whatever this machine's settings say.
	for key: StringName in DebugSettings.DEFAULTS:
		SettingsManager.debug.preview(key, false)


func after_each() -> void:
	Globals.debug_time_offset = _saved_offset
	for key: StringName in DebugSettings.DEFAULTS:
		SettingsManager.debug.preview(key, SettingsManager.debug.is_on(key))


func _section(title_key: String) -> ReadoutSection:
	for child in _panel.get_children():
		if child is ReadoutSection and (child as ReadoutSection).title_key == title_key:
			return child
	return null


func test_hidden_while_every_toggle_is_off() -> void:
	assert_false(_panel.is_shown(), "nothing to show")


func test_the_f8_force_shows_it_filled_in_the_same_frame() -> void:
	SettingsManager.debug.preview(&"show_debug", true)  # what Screenshot does for a bug-report capture
	assert_true(_panel.is_shown(), "shown at once, not at the next frame")
	assert_string_contains(_section("%%HUD_DEV_CLIENT").text(), "FPS", "and already filled")
	SettingsManager.debug.preview(&"show_debug", false)
	assert_false(_panel.is_shown(), "and gone when the capture restores the setting")


func test_the_clock_alert_shows_with_the_panels_off() -> void:
	Globals.debug_time_offset = 2.0 * 3600.0
	_panel.reevaluate()
	assert_true(_panel.is_shown(), "the alert alone brings the panel up")
	assert_false(_section("%%HUD_DEV_CLIENT").box.visible, "without the debug readouts")


func test_the_vehicle_section_needs_the_setting_and_a_wheel() -> void:
	SettingsManager.debug.preview(&"vehicle_hud", true)
	assert_false(_panel.is_shown(), "not driving: nothing to show")
	_driving = Vehicle.new()
	autofree(_driving)
	_panel.reevaluate()
	assert_true(_section("%%HUD_DEV_VEHICLE").box.visible, "at the wheel with the dashboard on")


func test_it_sits_on_the_right() -> void:
	assert_eq(_panel._panel.anchor_left, 1.0, "right edge, the graphics panel has the left")


func test_only_the_server_box_is_capped() -> void:
	assert_gt(_section("%%HUD_DEV_SERVER_BOX").max_height_px, 0.0, "the zone list scrolls on its own")
	assert_eq(_section("%%HUD_DEV_CLIENT").max_height_px, 0.0, "the other sections grow with their text")


func test_the_music_section_has_its_own_switch() -> void:
	SettingsManager.debug.preview(&"music_debug", true)
	assert_true(_section("%%HUD_DEV_MUSIC").box.visible, "shown without the other debug readouts")
	assert_false(_section("%%HUD_DEV_CLIENT").box.visible, "which stay off")


func test_the_star_map_section_needs_its_switch_and_the_map_open() -> void:
	SettingsManager.debug.preview(&"star_map_debug", true)
	assert_false(_panel.is_shown(), "map closed: nothing to show")
	_map.show()
	_panel.reevaluate()
	assert_true(_section("%%HUD_DEV_STAR_MAP").box.visible, "open, with its switch on")
	assert_string_contains(_section("%%HUD_DEV_STAR_MAP").text(), "22 bodies", "the map's own lines")
	assert_false(_section("%%HUD_DEV_CLIENT").box.visible, "without the other debug readouts")


func test_over_the_open_map_and_back_under_once_closed() -> void:
	SettingsManager.debug.preview(&"star_map_debug", true)
	_map.show()
	_panel.reevaluate()
	assert_eq(_panel.layer, StarMap.LAYER + 1, "the chart is opaque: the panel goes over it")
	assert_eq(_map.inset, _panel.footprint_px(), "and the chart's info panel steps aside")
	_map.hide()
	assert_eq(_panel.layer, OverlayPanel.LAYER, "back under the menus")
	assert_eq(_map.inset, 0.0, "the corner is the info panel's again")
