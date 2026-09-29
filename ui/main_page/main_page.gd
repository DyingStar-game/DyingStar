class_name MainPage
extends CanvasLayer

## Which screen is showing: &"home", &"settings", or &"settings_graphics". The menu stage (when the
## menu stands on one) glides its camera to match; the menu itself knows nothing of any stage.
signal screen_changed(screen: StringName)

const LOGO : Texture2D = preload("res://ui/main_page/dyingstar-logo.png")
const _LOGO_WIDTH_PX : float = 620.0

## Brightness applied to a button's background sprite while hovered (the FlatButton itself is
## transparent, so the look comes from its button.png sprite — mimics the default button hover).
const HOVER_TINT := Color(1.4, 1.4, 1.4)

var is_ready: bool = false
var settings_scene : PackedScene = preload("res://ui/settings_page/settings_page.tscn")
## The settings overlay while it is open, else null — so Esc closes it (back to the main menu) the same
## way it does in the pause menu, instead of doing nothing.
var _settings_overlay: Node = null
## A live 3D stage stands behind the menu: no still background, the logo on its own, see-through settings.
var _stage_mode : bool = false
## The tuning scene has the screen: the menu steps aside (and leaves Esc to it).
var _interface_hidden : bool = false
var _logo : TextureRect = null

@onready var settings_button : Button = $Control/Button
@onready var quit_button : Button = $Control/QuitButton
@onready var settings_bg : TextureRect = $Control/Button2
@onready var quit_bg : TextureRect = $Control/Button3

func _ready() -> void:
	settings_button.pressed.connect(_on_settings_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	_add_hover_highlight(settings_button, settings_bg)
	_add_hover_highlight(quit_button, quit_bg)
	is_ready = true

## Lighten a button's background sprite while the mouse is over it (hover feedback).
func _add_hover_highlight(button: Button, bg: TextureRect) -> void:
	button.mouse_entered.connect(func() -> void: bg.modulate = HOVER_TINT)
	button.mouse_exited.connect(func() -> void: bg.modulate = Color.WHITE)

## Esc closes the settings overlay (back to the main menu). No-op when it is already closed. The
## host menu owns its overlay's lifecycle, mirroring the pause menu — see PauseMenu._unhandled_input.
func _unhandled_input(event: InputEvent) -> void:
	if _interface_hidden:
		return
	if event.is_action_pressed("pause") and is_instance_valid(_settings_overlay):
		_settings_overlay.queue_free()
		_settings_overlay = null
		get_viewport().set_input_as_handled()

func _on_settings_pressed() -> void:
	# Track the overlay so Esc closes it (back), and drop the ref if its own Return button frees it.
	_settings_overlay = settings_scene.instantiate()
	_settings_overlay.see_through = _stage_mode
	# Connected before it enters the tree: its _ready opens the first category, which must be heard.
	_settings_overlay.category_changed.connect(_on_category_changed)
	_settings_overlay.tree_exited.connect(_on_settings_closed)
	add_child(_settings_overlay)
	# Over a stage the settings are see-through: the menu's own buttons would show under them.
	$Control.visible = not _stage_mode


func _on_settings_closed() -> void:
	_settings_overlay = null
	$Control.visible = not _interface_hidden
	screen_changed.emit(&"home")


func _on_category_changed(key: String) -> void:
	screen_changed.emit(&"settings_graphics" if key == "%%MENU_CAT_GRAPHICS" else &"settings")


## A live 3D stage now stands behind the menu (MenuStage): drop the still image, show the logo alone.
func set_stage_mode(on: bool) -> void:
	_stage_mode = on
	$Control/Background.visible = not on
	if on and _logo == null:
		_logo = TextureRect.new()
		_logo.texture = LOGO
		_logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		_logo.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_logo.offset_left = -_LOGO_WIDTH_PX / 2.0
		_logo.offset_right = _LOGO_WIDTH_PX / 2.0
		_logo.offset_top = 48.0
		_logo.offset_bottom = 48.0 + _LOGO_WIDTH_PX * LOGO.get_height() / LOGO.get_width()
		_logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
		$Control.add_child(_logo)
	if _logo != null:
		_logo.visible = on


## Step aside for the tuning scene, and come back.
func set_interface_hidden(on: bool) -> void:
	_interface_hidden = on
	$Control.visible = not on and _settings_overlay == null
	if is_instance_valid(_settings_overlay):
		_settings_overlay.visible = not on

func _on_quit_pressed() -> void:
	get_tree().quit()

func _on_button_pressed() -> void:
	GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
