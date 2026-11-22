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
const CHARACTER : StringName = &"character"
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

## The settings page, LOADED when it is first opened — never preloaded. A preload closed a loop:
## the settings preload their Graphics tab, which knows the menu stage (its hour slider), which knows
## this page, which preloaded the settings. In an exported build the scene caught in that loop loads
## EMPTY ("node count is 0"): from a fresh launch Settings, Credits and Back did nothing until a visit
## to the game had loaded the settings another way. The editor loads scripts differently and never
## showed it.
const SETTINGS_SCENE_PATH : String = "res://ui/settings_page/settings_page.tscn"
## The character creator, loaded when opened, for the same reason.
const CREATOR_SCENE_PATH : String = "res://ui/character_creator/character_creator.tscn"

var is_ready: bool = false
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
## Bottom left of the home screen: the graphics driver is too old (when it is, see DriverAge), over the
## development notice — the game is in development, much is a placeholder, nothing is final.
var _notice : VBoxContainer = null

func _ready() -> void:
	# The background fills the screen; the menu itself (logo, buttons) keeps to a centred 16:9 area.
	var background : TextureRect = $Control/Background
	background.reparent(self)
	move_child(background, 0)
	SafeArea.keep($Control)
	bar = TopBar.new()
	bar.add_entry(ENTER, "%%MAINPAGE_ENTER")
	bar.add_entry(CHARACTER, "%%MENU_CHARACTER")
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
	_notice = _notices()
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
			# A player with no look kept here yet makes one first (or keeps the one offered).
			if CharacterStore.saved() == null:
				_open_creator(true)
			else:
				_enter_universe()
		CHARACTER:
			_open_creator(false)
		SETTINGS:
			_open_overlay(SETTINGS)
		CREDITS:
			_open_overlay(CREDITS)
		QUIT:
			GameOrchestrator.quit_game()

## Esc closes the settings overlay (back to the main menu). No-op when it is already closed. The
## host menu owns its overlay's lifecycle, mirroring the pause menu — see PauseMenu._unhandled_input.
func _unhandled_input(event: InputEvent) -> void:
	# Esc, or B on the gamepad (ui_cancel).
	if (event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")) \
			and is_instance_valid(_settings_overlay):
		_close_settings()
		get_viewport().set_input_as_handled()


func _enter_universe() -> void:
	GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)


## The character creator, in the overlay's place (Esc or the bar's arrow close it, as the settings).
## [param first_enter]: opened by "Enter universe"; its main button saves and enters.
func _open_creator(first_enter: bool) -> void:
	if is_instance_valid(_settings_overlay):
		if _overlay_entry == CHARACTER:
			return
		_settings_overlay.queue_free()
	var creator : Node = (load(CREATOR_SCENE_PATH) as PackedScene).instantiate()
	creator.set(&"first_enter", first_enter)
	creator.enter_requested.connect(_enter_universe)
	_settings_overlay = creator
	_overlay_entry = CHARACTER
	creator.tree_exited.connect(_on_settings_closed.bind(creator))
	add_child(creator)
	$Control.visible = false
	_notice.visible = false
	bar.set_active(CHARACTER)
	bar.set_back_visible(true)
	screen_changed.emit(CHARACTER)


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
	var overlay : Node = (load(SETTINGS_SCENE_PATH) as PackedScene).instantiate()
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


## The notices of the home screen, bottom left, stacked upwards: the driver warning (only when the
## driver is too old) over the development notice.
func _notices() -> VBoxContainer:
	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	column.anchor_right = _NOTICE_WIDTH_SHARE
	column.grow_vertical = Control.GROW_DIRECTION_BEGIN
	column.offset_left = _QUALITY_MARGIN_PX
	column.offset_right = 0.0
	column.offset_bottom = -_QUALITY_MARGIN_PX
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 10)
	var driver : Dictionary = DriverAge.detect()
	if not driver.is_empty():
		print("[MainPage] graphics driver too old: %s Vulkan %s, %s or newer wanted — warning shown, download page %s"
				% [driver["vendor"], driver["found"], driver["needed"], driver["url"]])
		column.add_child(_driver_notice(driver))
	column.add_child(_dev_notice())
	return column


## A dark, see-through card, so it reads over the 3D stage as over the still background.
func _notice_card(border: Color = Color.TRANSPARENT) -> PanelContainer:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(14)
	if border.a > 0.0:
		style.border_color = border
		style.set_border_width_all(2)
	card.add_theme_stylebox_override("panel", style)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return card


func _notice_label(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_override("font", SettingsRowFactory.FONT)
	label.add_theme_font_size_override("font_size", _NOTICE_FONT_SIZE)
	label.add_theme_color_override("font_color", color)
	return label


## The development notice: the game is being built, many sounds and models are placeholders there to
## try the gameplay, nothing is final.
func _dev_notice() -> PanelContainer:
	var card : PanelContainer = _notice_card()
	card.add_child(_notice_label("%%MENU_DEV_NOTICE", Color(1.0, 1.0, 1.0, 0.85)))
	return card


## The graphics driver is too old (DriverAge): it can crash the game, here is where to get the right
## one. Players believe Windows Update keeps it current, so the text says it does not.
func _driver_notice(driver: Dictionary) -> PanelContainer:
	var card : PanelContainer = _notice_card(SettingsStyle.FAIR_COLOR)
	var lines := VBoxContainer.new()
	lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(lines)
	var title : Label = _notice_label("%%MENU_DRIVER_OLD_TITLE", SettingsStyle.FAIR_COLOR)
	lines.add_child(title)
	var body : Label = _notice_label("", Color(1.0, 1.0, 1.0, 0.9))
	body.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	lines.add_child(body)
	var link := Button.new()
	link.flat = true
	link.alignment = HORIZONTAL_ALIGNMENT_LEFT
	link.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	link.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	link.add_theme_font_override("font", SettingsRowFactory.FONT)
	link.add_theme_font_size_override("font_size", _NOTICE_FONT_SIZE)
	link.add_theme_color_override("font_color", SettingsStyle.ACTIVE_COLOR)
	link.tooltip_text = driver["url"]
	link.pressed.connect(func() -> void: OS.shell_open(driver["url"]))
	lines.add_child(link)
	var fill := func(_lang: String = "") -> void:
		body.text = tr("%%MENU_DRIVER_OLD_TEXT") % [driver["vendor"], driver["found"], driver["needed"]]
		link.text = tr("%%MENU_DRIVER_OLD_LINK") % driver["vendor"] + "  ›"
	fill.call()
	SettingsManager.language.changed.connect(fill)
	return card


func _label_quality() -> void:
	var render : RenderSettings = SettingsManager.render
	_quality.text = "%s : %s  ›" % [tr("%%MENU_GFX_PRESET"), tr(GraphicsOptions.PRESET_LABELS[render.preset()])]

## The graphics-quality button: Settings, straight on its Graphics tab.
func _open_graphics() -> void:
	_open_overlay(SETTINGS)
	_settings_overlay.open("%%MENU_CAT_GRAPHICS")
