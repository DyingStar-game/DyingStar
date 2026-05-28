extends CanvasLayer

var general_settings : PackedScene = preload("res://ui/settings_page/general_page/general_settings_page.tscn")
var graphic_settings : PackedScene = preload("res://ui/settings_page/graphical_page/graphical_settings_page.tscn")
var audio_settings : PackedScene = preload("res://ui/settings_page/audio_page/audio_settings_page.tscn")
var control_settings : PackedScene = preload("res://ui/settings_page/control_page/control_settings_page.tscn")

@onready var return_button : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Return
@onready var general_button : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Generals
@onready var graphic_button : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Graphics
@onready var audio_button : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Audio
@onready var control_button : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Controls
@onready var settings_container : SubViewport = $Control/MarginContainer/VBoxContainer/HBoxContainer/SubViewportContainer/SubViewport

func _ready() -> void:
	return_button.pressed.connect(queue_free)
	general_button.pressed.connect(open_settings.bind(general_settings))
	graphic_button.pressed.connect(open_settings.bind(graphic_settings))
	audio_button.pressed.connect(open_settings.bind(audio_settings))
	control_button.pressed.connect(open_settings.bind(control_settings))
	open_settings(general_settings)


func open_settings(settings : PackedScene) -> void:
	AudioManager.play_UI_sound(AudioManager.SOUND_UI_BUTTON)
	for child in settings_container.get_children():
		child.queue_free()
	settings_container.add_child(settings.instantiate())
