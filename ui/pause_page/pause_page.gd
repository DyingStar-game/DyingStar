extends Control

@onready var settings_button: Button = $MarginContainer/VBoxContainer/SettingsButton
@onready var quit_game_button: Button = $MarginContainer/VBoxContainer/QuitGameButton
@onready var return_menu_button: Button = $MarginContainer/VBoxContainer/ReturnMenuButton
@onready var resume_game_button: Button = $MarginContainer/VBoxContainer/ResumeGameButton

func _unhandled_input(_event: InputEvent) -> void:
	if not is_multiplayer_authority(): return
