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
	AltGr.reset()
	AltGr.check_keyboard = true


func _key(keycode: Key, pressed: bool, location: KeyLocation) -> InputEventKey:
	var key := InputEventKey.new()
	key.keycode = keycode
	key.location = location
	key.pressed = pressed
	return key


## AltGr as the rest of the game sees it: fed to AltGr (as Globals does), then a frame.
func _altgr(pressed: bool, location: KeyLocation = KEY_LOCATION_RIGHT) -> void:
	AltGr.check_keyboard = false  # no real key is down in a test
	AltGr.feed(_key(KEY_ALT, pressed, location))
	_overlay._process(0.0)


func test_holding_altgr_takes_the_pointer_and_releasing_gives_it_back() -> void:
	assert_false(_overlay.wants_pointer(), "the camera has the mouse to begin with")
	_altgr(true)
	assert_true(_overlay.wants_pointer(), "AltGr held: the panel has it")
	_altgr(false)
	assert_false(_overlay.wants_pointer(), "released: back to the camera")


func test_the_left_alt_does_nothing() -> void:
	_altgr(true, KEY_LOCATION_LEFT)
	assert_false(_overlay.wants_pointer(), "left Alt keeps its own shortcuts")


func test_altgr_is_left_to_the_chat_while_typing() -> void:
	_typing = true
	_altgr(true)
	assert_false(_overlay.wants_pointer(), "AltGr types @ # { } on AZERTY: not ours then")


func test_the_pause_menu_hides_it_and_drops_the_pointer() -> void:
	_altgr(true)
	_menu = true
	_overlay._process(0.0)
	assert_false(_overlay.is_shown(), "hidden under the pause menu")
	assert_false(_overlay.wants_pointer(), "and the pointer is dropped")


func test_switched_off_it_hides() -> void:
	_render.set_overlay_enabled(false)
	assert_false(_overlay.is_shown(), "Settings > General switch off hides it at once")
	_altgr(true)
	assert_false(_overlay.wants_pointer(), "a hidden overlay never takes the pointer")


func test_losing_the_window_drops_the_pointer() -> void:
	_altgr(true)
	Globals._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_overlay._process(0.0)
	assert_false(_overlay.wants_pointer(), "the release never arrives after an alt-tab")


func test_an_f7_photo_hides_it_for_its_frame() -> void:
	assert_true(_overlay.is_shown(), "on")
	# What Screenshot._hide_interface() does to every CanvasLayer, restored after the capture.
	_overlay.visible = false
	_overlay._process(0.0)
	assert_false(_overlay.visible, "the panel does not put itself back into the photo")
	assert_true(_overlay.is_shown(), "it still considers itself on")
	_overlay.visible = true
	assert_true(_overlay._panel.visible, "and is there again once the photo is taken")


func test_every_caption_wraps_instead_of_widening_the_panel() -> void:
	# An unwrapped caption ("Anticrénelage multi-échantillons (MSAA)") made its line wider than the
	# panel and cut the controls off on the right. Checked structurally: headless runs measure no
	# text, so a width test would pass whether the captions wrap or not.
	var captions : Array[Node] = _overlay._panel.find_children("*", "Label", true, false)
	assert_gt(captions.size(), GraphicsOptions.OPTIONS.size(), "the lines were built")
	for caption in captions:
		if (caption as Label).label_settings == null:
			continue  # a slider's number: short by construction
		if caption.get_parent() is HBoxContainer and caption.get_index() > 0:
			continue  # same: the value beside a slider
		assert_ne((caption as Label).autowrap_mode, TextServer.AUTOWRAP_OFF, "'%s' wraps" % caption.text)
