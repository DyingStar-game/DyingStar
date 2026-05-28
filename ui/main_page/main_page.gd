extends CanvasLayer

var is_ready: bool = false
var settings_scene : PackedScene = preload("res://ui/settings_page/settings_page.tscn")

@onready var settings_button : Button = $Control/Button
@onready var enter_button: Button = $Control/VBoxContainer/EnterButton

func _ready() -> void:
	# On connecte les boutons à leur méthodes
	settings_button.pressed.connect(_on_settings_pressed)
	enter_button.pressed.connect(_on_enter_pressed)
	is_ready = true

# On clique sur le bouton "Settings"
func _on_settings_pressed() -> void:
	AudioManager.play_UI_sound(AudioManager.SOUND_UI_BUTTON)
	add_child(settings_scene.instantiate())

# On clique sur le bouton "Entrer dans l'univers"
func _on_enter_pressed() -> void:
	AudioManager.play_UI_sound(AudioManager.SOUND_UI_IMPORTANT)
	GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
