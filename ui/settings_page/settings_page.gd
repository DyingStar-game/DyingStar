extends CanvasLayer

## Highlight colour for the category whose page is currently shown (clear "you are here"),
## so the active tab stays marked after the click instead of only on hover.
const ACTIVE_COLOR : Color = Color(1.0, 0.84, 0.35)
const INACTIVE_COLOR : Color = Color(1.0, 1.0, 1.0)

var general_settings : PackedScene = preload("res://ui/settings_page/general_page/general_settings_page.tscn")
var graphic_settings : PackedScene = preload("res://ui/settings_page/graphical_page/graphical_settings_page.tscn")
var audio_settings : PackedScene = preload("res://ui/settings_page/audio_page/audio_settings_page.tscn")
var control_settings : PackedScene = preload("res://ui/settings_page/control_page/control_settings_page.tscn")
var _category_buttons : Array[Button] = []

@onready var title_label : Label = $Control/MarginContainer/VBoxContainer/Label
@onready var return_button : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Return
@onready var general_button : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Generals
@onready var graphic_button : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Graphics
@onready var audio_button : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Audio
@onready var control_button : Button = $Control/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/Controls
@onready var settings_container : SubViewport = $Control/MarginContainer/VBoxContainer/HBoxContainer/SubViewportContainer/SubViewport

func _ready() -> void:
	_category_buttons = [general_button, graphic_button, audio_button, control_button]
	return_button.pressed.connect(queue_free)
	general_button.pressed.connect(open_settings.bind(general_settings, general_button, "General"))
	graphic_button.pressed.connect(open_settings.bind(graphic_settings, graphic_button, "Graphics"))
	audio_button.pressed.connect(open_settings.bind(audio_settings, audio_button, "Audio"))
	control_button.pressed.connect(open_settings.bind(control_settings, control_button, "Controls"))
	open_settings(general_settings, general_button, "General")


func open_settings(settings : PackedScene, active_button : Button, title : String) -> void:
	for child in settings_container.get_children():
		child.queue_free()
	settings_container.add_child(settings.instantiate())
	title_label.text = "Settings - " + title
	# Mark the active category (persists after the click) and reset the others.
	for button in _category_buttons:
		var label : Label = button.get_node("Label")
		label.modulate = ACTIVE_COLOR if button == active_button else INACTIVE_COLOR
