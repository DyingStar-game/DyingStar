extends CanvasLayer

## Brightness applied to a button's background sprite while hovered (the FlatButton itself is
## transparent, so the look comes from its button.png sprite — mimics the default button hover).
const HOVER_TINT := Color(1.4, 1.4, 1.4)

var is_ready: bool = false
var settings_scene : PackedScene = preload("res://ui/settings_page/settings_page.tscn")
## The settings overlay while it is open, else null — so Esc closes it (back to the main menu) the same
## way it does in the pause menu, instead of doing nothing.
var _settings_overlay: Node = null

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
	if event.is_action_pressed("pause") and is_instance_valid(_settings_overlay):
		_settings_overlay.queue_free()
		_settings_overlay = null
		get_viewport().set_input_as_handled()

func _on_settings_pressed() -> void:
	# Track the overlay so Esc closes it (back), and drop the ref if its own Return button frees it.
	_settings_overlay = settings_scene.instantiate()
	_settings_overlay.tree_exited.connect(func(): _settings_overlay = null)
	add_child(_settings_overlay)

func _on_quit_pressed() -> void:
	get_tree().quit()

func _on_button_pressed() -> void:
	GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
