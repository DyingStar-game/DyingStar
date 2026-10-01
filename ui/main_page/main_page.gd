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
const QUIT : StringName = &"quit"
## "Graphics quality" button, from the bottom-right corner.
const _QUALITY_MARGIN_PX : float = 40.0

var is_ready: bool = false
var settings_scene : PackedScene = preload("res://ui/settings_page/settings_page.tscn")
## The settings overlay while it is open, else null — so Esc closes it (back to the main menu) the same
## way it does in the pause menu, instead of doing nothing.
var _settings_overlay: Node = null
## A live 3D stage stands behind the menu: no still background, see-through settings.
var _stage_mode : bool = false
## Logo, Enter / Settings / Quit, and the way back from the settings (TopBar).
var bar : TopBar = null
## Bottom right of the home screen, over a stage: "Graphics quality: High" — the preset in use (the
## one detected for this GPU on a first launch), and a way straight to Settings > Graphics.
var _quality : Button = null

func _ready() -> void:
	# The background fills the screen; the menu itself (logo, buttons) keeps to a centred 16:9 area.
	var background : TextureRect = $Control/Background
	background.reparent(self)
	move_child(background, 0)
	SafeArea.keep($Control)
	bar = TopBar.new()
	bar.add_entry(ENTER, "%%MAINPAGE_ENTER")
	bar.add_entry(SETTINGS, "%%MENU_SETTINGS")
	bar.add_entry(QUIT, "%%MENU_QUIT")
	bar.entry_pressed.connect(_on_entry_pressed)
	bar.back_pressed.connect(_close_settings)
	bar.left_bottom.connect(func() -> void:
		if is_instance_valid(_settings_overlay):
			_settings_overlay.focus_first())
	add_child(bar)
	# A gamepad plugged in and not yet taken up: say it can drive the menu.
	$Control.add_child(PadInvite.new())
	is_ready = true


func _on_entry_pressed(key: StringName) -> void:
	match key:
		ENTER:
			GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
		SETTINGS:
			if not is_instance_valid(_settings_overlay):
				_on_settings_pressed()
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

func _on_settings_pressed() -> void:
	# Track the overlay so Esc or the bar's arrow closes it (back).
	_settings_overlay = settings_scene.instantiate()
	_settings_overlay.see_through = _stage_mode
	# Connected before it enters the tree: its _ready opens the first category, which must be heard.
	_settings_overlay.category_changed.connect(_on_category_changed)
	_settings_overlay.tree_exited.connect(_on_settings_closed)
	_settings_overlay.left_top.connect(bar.focus_entry)
	add_child(_settings_overlay)
	# Over a stage the settings are see-through: the menu's own buttons would show under them.
	$Control.visible = not _stage_mode
	# The page's lines are what the pad or the arrows move through now, not the bar's entries.
	bar.leads_focus = false
	bar.set_active(SETTINGS)
	bar.set_back_visible(true)


func _on_settings_closed() -> void:
	_settings_overlay = null
	$Control.visible = true
	bar.leads_focus = true
	# Back on the bar, where you came from: on the pad, the Settings entry has the focus again.
	if not InputDevice.pointer and bar.tabs.button(SETTINGS) != null:
		bar.tabs.button(SETTINGS).grab_focus()
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


func _label_quality() -> void:
	var render : RenderSettings = SettingsManager.render
	_quality.text = "%s : %s  ›" % [tr("%%MENU_GFX_PRESET"), tr(GraphicsOptions.PRESET_LABELS[render.preset()])]

## The graphics-quality button: Settings, straight on its Graphics tab.
func _open_graphics() -> void:
	if not is_instance_valid(_settings_overlay):
		_on_settings_pressed()
	_settings_overlay.open("%%MENU_CAT_GRAPHICS")
