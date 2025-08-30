extends Control

@onready var keymapping_button: Button = $MarginContainer/VBoxContainer/KeymappingButton
@onready var quit_game_button: Button = $MarginContainer/VBoxContainer/QuitGameButton
@onready var resume_game_button: Button = $MarginContainer/VBoxContainer/ResumeGameButton

func _ready() -> void:
	pass

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority(): return
	pass
