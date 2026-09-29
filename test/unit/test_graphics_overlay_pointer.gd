extends GutTest
## GraphicsOverlay: holding AltGr (the RIGHT Alt) hands the mouse to the panel, releasing it gives it
## back — and only while the overlay is on, shown, and the player is not typing somewhere.
## SettingsManager.render is swapped for a throwaway model: the real settings file is never written.

var _real_render : RenderSettings
var _render : RenderSettings
var _overlay : GraphicsOverlay
var _typing : bool = false
var _menu : bool = false


func before_each() -> void:
	_real_render = SettingsManager.render
	_render = RenderSettings.new(ConfigFile.new(), func() -> void: pass, {"method": "forward_plus"})
	_render.ensure_initialized(false)
	_render.set_overlay_enabled(true)
	SettingsManager.render = _render
	_typing = false
	_menu = false
	_overlay = GraphicsOverlay.new()
	_overlay.setup(func() -> bool: return not _typing, func() -> bool: return _menu)
	add_child_autofree(_overlay)


func after_each() -> void:
	SettingsManager.render = _real_render


func _alt(pressed: bool, location: KeyLocation = KEY_LOCATION_RIGHT) -> InputEventKey:
	var key := InputEventKey.new()
	key.keycode = KEY_ALT
	key.location = location
	key.pressed = pressed
	return key


func test_holding_altgr_takes_the_pointer_and_releasing_gives_it_back() -> void:
	assert_false(_overlay.wants_pointer(), "the camera has the mouse to begin with")
	_overlay._input(_alt(true))
	assert_true(_overlay.wants_pointer(), "AltGr held: the panel has it")
	_overlay._input(_alt(false))
	assert_false(_overlay.wants_pointer(), "released: back to the camera")


func test_the_left_alt_does_nothing() -> void:
	_overlay._input(_alt(true, KEY_LOCATION_LEFT))
	assert_false(_overlay.wants_pointer(), "left Alt keeps its own shortcuts")


func test_altgr_is_left_to_the_chat_while_typing() -> void:
	_typing = true
	_overlay._input(_alt(true))
	assert_false(_overlay.wants_pointer(), "AltGr types @ # { } on AZERTY: not ours then")


func test_the_pause_menu_hides_it_and_drops_the_pointer() -> void:
	_overlay._input(_alt(true))
	_menu = true
	_overlay._process(0.0)
	assert_false(_overlay.visible, "hidden under the pause menu")
	assert_false(_overlay.wants_pointer(), "and the pointer is dropped")


func test_switched_off_it_hides() -> void:
	_render.set_overlay_enabled(false)
	assert_false(_overlay.visible, "Settings > General switch off hides it at once")
	_overlay._input(_alt(true))
	assert_false(_overlay.wants_pointer(), "a hidden overlay never takes the pointer")


func test_losing_the_window_drops_the_pointer() -> void:
	_overlay._input(_alt(true))
	_overlay._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_false(_overlay.wants_pointer(), "the release never arrives after an alt-tab")
