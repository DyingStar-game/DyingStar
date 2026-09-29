extends GutTest
## DevOverlay: the debug readouts in one panel on the right. The F8 capture forces the debug panels
## for ONE frame through show_debug_changed; they must be up and filled in that very frame. The dev
## clock alert shows even with the debug panels off. Signals are emitted directly: nothing is saved.

var _saved_offset : float = 0.0
var _panel : OverlayPanel
var _driving : Vehicle = null


func before_each() -> void:
	_saved_offset = Globals.debug_time_offset
	Globals.debug_time_offset = 0.0
	var body := Node3D.new()
	add_child_autofree(body)
	_panel = DevOverlay.create(body, null, func() -> Dictionary: return {}, func() -> Vehicle: return _driving)
	add_child_autofree(_panel)
	# Start from "everything off", whatever this machine's settings say.
	for sig in [SettingsManager.show_debug_changed, SettingsManager.surface_debug_changed,
			SettingsManager.movement_debug_changed, SettingsManager.vehicle_hud_changed]:
		sig.emit(false)


func after_each() -> void:
	Globals.debug_time_offset = _saved_offset
	SettingsManager.show_debug_changed.emit(SettingsManager.is_show_debug())


func _section(title_key: String) -> ReadoutSection:
	for child in _panel.get_children():
		if child is ReadoutSection and (child as ReadoutSection).title_key == title_key:
			return child
	return null


func test_hidden_while_every_toggle_is_off() -> void:
	assert_false(_panel.is_shown(), "nothing to show")


func test_the_f8_force_shows_it_filled_in_the_same_frame() -> void:
	SettingsManager.show_debug_changed.emit(true)  # what Screenshot does for a bug-report capture
	assert_true(_panel.is_shown(), "shown at once, not at the next frame")
	assert_string_contains(_section("%%HUD_DEV_CLIENT").text(), "FPS", "and already filled")
	SettingsManager.show_debug_changed.emit(false)
	assert_false(_panel.is_shown(), "and gone when the capture restores the setting")


func test_the_clock_alert_shows_with_the_panels_off() -> void:
	Globals.debug_time_offset = 2.0 * 3600.0
	_panel.reevaluate()
	assert_true(_panel.is_shown(), "the alert alone brings the panel up")
	assert_false(_section("%%HUD_DEV_CLIENT").box.visible, "without the debug readouts")


func test_the_vehicle_section_needs_the_setting_and_a_wheel() -> void:
	SettingsManager.vehicle_hud_changed.emit(true)
	assert_false(_panel.is_shown(), "not driving: nothing to show")
	_driving = Vehicle.new()
	autofree(_driving)
	_panel.reevaluate()
	assert_true(_section("%%HUD_DEV_VEHICLE").box.visible, "at the wheel with the dashboard on")


func test_it_sits_on_the_right() -> void:
	assert_eq(_panel._panel.anchor_left, 1.0, "right edge, the graphics panel has the left")
