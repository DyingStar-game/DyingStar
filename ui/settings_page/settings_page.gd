extends CanvasLayer


@onready var ReturnButton : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Return
@onready var GeneralButton : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Generals
@onready var GraphicButton : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Graphics
@onready var AudioButton : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Audio
@onready var ControlButton : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Controls
@onready var SettingsContainer : SubViewport = $Control/MarginContainer/VBoxContainer/HBoxContainer/SubViewportContainer/SubViewport

var general_settings : PackedScene = preload("res://ui/settings_page/general_page/general_settings_page.tscn")
var graphic_settings : PackedScene = preload("res://ui/settings_page/graphical_page/graphical_settings_page.tscn")
var audio_settings : PackedScene = preload("res://ui/settings_page/audio_page/audio_settings_page.tscn")
var control_settings : PackedScene = preload("res://ui/settings_page/control_page/control_settings_page.tscn")


func _ready() -> void:
	ReturnButton.pressed.connect(queue_free)
	GeneralButton.pressed.connect(open_settings.bind(general_settings))
	GraphicButton.pressed.connect(open_settings.bind(graphic_settings))
	AudioButton.pressed.connect(open_settings.bind(audio_settings))
	ControlButton.pressed.connect(open_settings.bind(control_settings))
	open_settings(general_settings)


func open_settings(settings : PackedScene) -> void:
	for child in SettingsContainer.get_children():
		child.queue_free()
	SettingsContainer.add_child(settings.instantiate())
