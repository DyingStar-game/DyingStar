class_name MainPage
extends CanvasLayer

## Which screen is showing: &"home", or one per settings category (SCREEN_OF_CATEGORY). The menu
## stage (when the menu stands on one) glides its camera to match; the menu knows nothing of any stage.
signal screen_changed(screen: StringName)

## The screen each settings category is: a viewpoint of the stage has the same key.
const SCREEN_OF_CATEGORY : Dictionary = {
	"%%MENU_CAT_GENERAL": &"settings", "%%MENU_CAT_GRAPHICS": &"settings_graphics",
	"%%MENU_CAT_AUDIO": &"settings_audio", "%%MENU_CAT_CONTROLS": &"settings_controls",
}

## The top bar's entries.
const ENTER : StringName = &"enter"
const SETTINGS : StringName = &"settings"
const CREDITS : StringName = &"credits"
const QUIT : StringName = &"quit"
## "Graphics quality" button, from the bottom-right corner.
const _QUALITY_MARGIN_PX : float = 40.0
## The development notice, bottom left of the home screen: the share of the screen's width it spans (the
## rest leaves room for the graphics-quality button, bottom right) and its text size. A fixed 620 px
## made a narrow column of it on a wide screen.
const _NOTICE_WIDTH_SHARE : float = 0.6
const _NOTICE_FONT_SIZE : int = 18

var is_ready: bool = false
var settings_scene : PackedScene = preload("res://ui/settings_page/settings_page.tscn")
## The settings (or credits) overlay while it is open, else null — so Esc closes it (back to the main
## menu) the same way it does in the pause menu, instead of doing nothing.
var _settings_overlay: Node = null
## The bar entry the overlay belongs to (SETTINGS or CREDITS): marked active, and focused again on close.
var _overlay_entry : StringName = &""
## A live 3D stage stands behind the menu: no still background, see-through settings.
var _stage_mode : bool = false
## Logo, Enter / Settings / Credits / Quit, and the way back from the settings (TopBar).
var bar : TopBar = null
## Bottom right of the home screen, over a stage: "Graphics quality: High" — the preset in use (the
## one detected for this GPU on a first launch), and a way straight to Settings > Graphics.
var _quality : Button = null
## Bottom left of the home screen: the game is in development, much is a placeholder, nothing is final.
var _notice : PanelContainer = null

func _ready() -> void:
	# The background fills the screen; the menu itself (logo, buttons) keeps to a centred 16:9 area.
	var background : TextureRect = $Control/Background
	background.reparent(self)
	move_child(background, 0)
	SafeArea.keep($Control)
	bar = TopBar.new()
	bar.add_entry(ENTER, "%%MAINPAGE_ENTER")
	bar.add_entry(SETTINGS, "%%MENU_SETTINGS")
	bar.add_entry(CREDITS, "%%MENU_CAT_CREDITS")
	bar.add_entry(QUIT, "%%MENU_QUIT")
	bar.entry_pressed.connect(_on_entry_pressed)
	bar.back_pressed.connect(_close_settings)
	# LT / RT from inside the settings: out of them, as B would, onto the bar's next or previous entry.
	bar.took_focus.connect(func() -> void:
		if is_instance_valid(_settings_overlay):
			_close_settings())
	add_child(bar)
	_notice = _dev_notice()
	$Control.add_child(_notice)
	# A gamepad plugged in: say it can drive the menus — at once, and when one is plugged in later.
	_offer_pad.call_deferred()
	Input.joy_connection_changed.connect(func(_device: int, connected: bool) -> void:
		if connected:
			_offer_pad())
	is_ready = true


## The "Gamepad detected" window, when a pad is there and it has not come up yet this launch.
func _offer_pad() -> void:
	if not is_inside_tree() or not PadPopup.wanted() or get_node_or_null("PadPopup") != null:
		return
	var popup := PadPopup.new()
	popup.name = "PadPopup"
	# Closed with the pad's A: the menu is driven from the pad now, from the bar's first entry.
	popup.closed.connect(func() -> void:
		if not InputDevice.pointer and not is_instance_valid(_settings_overlay):
			MenuFocus.take(bar.tabs))
	add_child(popup)


func _on_entry_pressed(key: StringName) -> void:
	match key:
		ENTER:
			GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
		SETTINGS:
			_open_overlay(SETTINGS)
		CREDITS:
			_open_overlay(CREDITS)
		QUIT:
			get_tree().quit()

## Esc closes the settings overlay (back to the main menu). No-op when it is already closed. The
## host menu owns its overlay's lifecycle, mirroring the pause menu — see PauseMenu._unhandled_input.
func _unhandled_input(event: InputEvent) -> void:
	# Esc, or B on the gamepad (ui_cancel).
	if (event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")) \
			and is_instance_valid(_settings_overlay):
		_close_settings()
		get_viewport().set_input_as_handled()


## Back from the settings: Esc or the bar's arrow.
func _close_settings() -> void:
	if is_instance_valid(_settings_overlay):
		_settings_overlay.queue_free()

## The settings frame under the bar for the bar's [param entry]: the settings, or the credits in the
## same frame. Already open for that entry: nothing; open for the other: swapped.
func _open_overlay(entry: StringName) -> void:
	if is_instance_valid(_settings_overlay):
		if _overlay_entry == entry:
			return
		_settings_overlay.queue_free()
	# Track the overlay so Esc or the bar's arrow closes it (back).
	var overlay : Node = settings_scene.instantiate()
	overlay.show_credits = entry == CREDITS
	overlay.see_through = _stage_mode
	_settings_overlay = overlay
	_overlay_entry = entry
	# Connected before it enters the tree: its _ready opens the first category, which must be heard.
	overlay.category_changed.connect(_on_category_changed)
	overlay.tree_exited.connect(_on_settings_closed.bind(overlay))
	add_child(overlay)
	# The page's lines are what the pad or the arrows move through now, not the bar's entries.
	bar.attach_page(overlay)
	# Over a stage the settings are see-through: the menu's own buttons would show under them.
	$Control.visible = not _stage_mode
	_notice.visible = false
	bar.set_active(entry)
	bar.set_back_visible(true)


## [param overlay] left: back to the home screen — unless another one already took its place.
func _on_settings_closed(overlay: Node) -> void:
	if overlay != _settings_overlay:
		return
	_settings_overlay = null
	# The whole menu is leaving (the game closes with the overlay open): nothing to hand back.
	if not is_inside_tree():
		return
	$Control.visible = true
	_notice.visible = true
	# Back on the bar, where you came from: on the pad, its entry has the focus again — unless the
	# triggers closed the overlay, and already put the focus on the entry they stepped to.
	var focused : Control = get_viewport().gui_get_focus_owner()
	var on_bar : bool = focused != null and bar.tabs.is_ancestor_of(focused)
	if not InputDevice.pointer and not on_bar and bar.tabs.button(_overlay_entry) != null:
		bar.tabs.button(_overlay_entry).grab_focus()
	_overlay_entry = &""
	bar.set_active(&"")
	bar.set_back_visible(false)
	screen_changed.emit(&"home")


func _on_category_changed(key: String) -> void:
	screen_changed.emit(SCREEN_OF_CATEGORY.get(key, &"settings"))


## A live 3D stage now stands behind the menu (MenuStage): drop the still image.
func set_stage_mode(on: bool) -> void:
	_stage_mode = on
	$Background.visible = not on
	if on and _quality == null:
		_quality = Button.new()
		_quality.add_theme_font_override("font", SettingsRowFactory.FONT)
		_quality.add_theme_font_size_override("font_size", 22)
		_quality.add_theme_color_override("font_color", SettingsStyle.GOOD_COLOR)
		_quality.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		_quality.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		_quality.grow_vertical = Control.GROW_DIRECTION_BEGIN
		_quality.offset_right = -_QUALITY_MARGIN_PX
		_quality.offset_bottom = -_QUALITY_MARGIN_PX
		_quality.tooltip_text = SettingsText.tooltip(tr("%%MENU_GFX_HELP_PRESET"))
		_quality.pressed.connect(_open_graphics)
		$Control.add_child(_quality)
		SettingsManager.render.changed.connect(func(_keys: PackedStringArray) -> void: _label_quality())
		SettingsManager.language.changed.connect(func(_lang: String) -> void: _label_quality())
		_label_quality()
	if _quality != null:
		_quality.visible = on


## The development notice: the game is being built, many sounds and models are placeholders there to
## try the gameplay, nothing is final. On a dark, see-through card so it reads over the 3D stage as over
## the still background.
func _dev_notice() -> PanelContainer:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(14)
	card.add_theme_stylebox_override("panel", style)
	card.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	card.anchor_right = _NOTICE_WIDTH_SHARE
	card.grow_vertical = Control.GROW_DIRECTION_BEGIN
	card.offset_left = _QUALITY_MARGIN_PX
	card.offset_right = 0.0
	card.offset_bottom = -_QUALITY_MARGIN_PX
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var text := Label.new()
	text.text = "%%MENU_DEV_NOTICE"
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_theme_font_override("font", SettingsRowFactory.FONT)
	text.add_theme_font_size_override("font_size", _NOTICE_FONT_SIZE)
	text.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.85))
	card.add_child(text)
	return card


func _label_quality() -> void:
	var render : RenderSettings = SettingsManager.render
	_quality.text = "%s : %s  ›" % [tr("%%MENU_GFX_PRESET"), tr(GraphicsOptions.PRESET_LABELS[render.preset()])]

## The graphics-quality button: Settings, straight on its Graphics tab.
func _open_graphics() -> void:
	_open_overlay(SETTINGS)
	_settings_overlay.open("%%MENU_CAT_GRAPHICS")
