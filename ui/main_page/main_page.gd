extends CanvasLayer

var is_ready: bool = false
var settings_scene : PackedScene = preload("res://ui/settings_page/settings_page.tscn")

@onready var settings_button : Button = $Control/Button

func _ready() -> void:
	settings_button.pressed.connect(_on_settings_pressed)
	is_ready = true

func _on_settings_pressed() -> void:
	add_child(settings_scene.instantiate())

func _on_button_pressed() -> void:
	GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
