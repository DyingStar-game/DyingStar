extends CanvasLayer

var general_settings : PackedScene = preload("res://ui/settings_page/general_page/general_settings_page.tscn")
var graphic_settings : PackedScene = preload("res://ui/settings_page/graphical_page/graphical_settings_page.tscn")
var audio_settings : PackedScene = preload("res://ui/settings_page/audio_page/audio_settings_page.tscn")
var control_settings : PackedScene = preload("res://ui/settings_page/control_page/control_settings_page.tscn")
var _category_buttons : Array[Button] = []
## Key of the category on show, kept so the title can be rebuilt in a new language.
var _category_key : String = ""

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
	general_button.pressed.connect(
			open_settings.bind(general_settings, general_button, "%%MENU_CAT_GENERAL"))
	graphic_button.pressed.connect(
			open_settings.bind(graphic_settings, graphic_button, "%%MENU_CAT_GRAPHICS"))
	audio_button.pressed.connect(
			open_settings.bind(audio_settings, audio_button, "%%MENU_CAT_AUDIO"))
	control_button.pressed.connect(
			open_settings.bind(control_settings, control_button, "%%MENU_CAT_CONTROLS"))
	open_settings(general_settings, general_button, "%%MENU_CAT_GENERAL")
	SettingsManager.language.changed.connect(_on_language_changed)


func open_settings(settings : PackedScene, active_button : Button, category_key : String) -> void:
	for child in settings_container.get_children():
		child.queue_free()
	settings_container.add_child(settings.instantiate())
	_category_key = category_key
	_apply_title()
	# Mark the active category (persists after the click) and reset the others.
	for button in _category_buttons:
		var label : Label = button.get_node("Label")
		label.modulate = (SettingsStyle.ACTIVE_COLOR if button == active_button
				else SettingsStyle.INACTIVE_COLOR)


## The title joins two translated pieces, so the WHOLE pattern is translated rather than glued from
## "Settings - " and a name: word order is not universal, and a concatenation cannot be reordered.
## Assembling it by hand also means it does not re-translate itself, hence _on_language_changed.
func _apply_title() -> void:
	title_label.text = tr("%%MENU_SETTINGS_TITLE") % tr(_category_key)


func _on_language_changed(_language: String) -> void:
	_apply_title()
