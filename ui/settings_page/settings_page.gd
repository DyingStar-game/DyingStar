extends CanvasLayer


@onready var RETURN_BUTTON : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Return
@onready var GENERAL_BUTTON : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Generals
@onready var GRAPHIC_BUTTON : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Graphics
@onready var AUDIO_BUTTON : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Audio
@onready var CONTROL_BUTTON : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Controls
@onready var SETTINGS_CONTAINER : SubViewport = $Control/MarginContainer/VBoxContainer/HBoxContainer/SubViewportContainer/SubViewport

var general_settings : PackedScene = preload("res://ui/settings_page/general_page/general_settings_page.tscn")
var graphic_settings : PackedScene = preload("res://ui/settings_page/graphical_page/graphical_settings_page.tscn")
var audio_settings : PackedScene = preload("res://ui/settings_page/audio_page/audio_settings_page.tscn")
var control_settings : PackedScene = preload("res://ui/settings_page/control_page/control_settings_page.tscn")


func _ready() -> void:
	RETURN_BUTTON.pressed.connect(queue_free)
	GENERAL_BUTTON.pressed.connect(open_settings.bind(general_settings))
	GRAPHIC_BUTTON.pressed.connect(open_settings.bind(graphic_settings))
	AUDIO_BUTTON.pressed.connect(open_settings.bind(audio_settings))
	CONTROL_BUTTON.pressed.connect(open_settings.bind(control_settings))
	open_settings(general_settings)


func open_settings(settings : PackedScene) -> void:
	for child in SETTINGS_CONTAINER.get_children():
		child.queue_free()
	SETTINGS_CONTAINER.add_child(settings.instantiate())
