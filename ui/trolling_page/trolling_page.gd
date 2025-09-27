extends Control

@onready var video_player: VideoStreamPlayer = $CenterContainer/VideoStreamPlayer
@onready var return_button: Button = $MarginContainer/Button

func _ready() -> void:
	return_button.connect("pressed", _on_button_pressed.bind("return"))
	video_player.scale = Vector2(1.5,1.5)
	video_player.play()

func _on_button_pressed(button_id: String) -> void:
	match button_id:
		"return":
			GameOrchestrator.change_game_state(GameOrchestrator.GameStates.HOME_MENU)
