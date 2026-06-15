extends CanvasLayer

## Brightness applied to a button's background sprite while hovered (the FlatButton itself is
## transparent, so the look comes from its button.png sprite — mimics the default button hover).
const HOVER_TINT := Color(1.4, 1.4, 1.4)

var is_ready: bool = false
var settings_scene : PackedScene = preload("res://ui/settings_page/settings_page.tscn")

@onready var settings_button : Button = $Control/Button
@onready var quit_button : Button = $Control/QuitButton
@onready var settings_bg : Sprite2D = $Control/Button2
@onready var quit_bg : Sprite2D = $Control/Button3

func _ready() -> void:
	settings_button.pressed.connect(_on_settings_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	_add_hover_highlight(settings_button, settings_bg)
	_add_hover_highlight(quit_button, quit_bg)
	is_ready = true

## Lighten a button's background sprite while the mouse is over it (hover feedback).
func _add_hover_highlight(button: Button, bg: Sprite2D) -> void:
	button.mouse_entered.connect(func() -> void: bg.modulate = HOVER_TINT)
	button.mouse_exited.connect(func() -> void: bg.modulate = Color.WHITE)

func _on_settings_pressed() -> void:
	add_child(settings_scene.instantiate())

func _on_quit_pressed() -> void:
	get_tree().quit()

func _on_button_pressed() -> void:
	GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
