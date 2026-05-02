@tool
class_name PlayerUI extends Control

const ICON_SPEAKER_ON = preload("res://ui/player_interface/volume-high-solid-full.svg")
const ICON_SPEAKER_OFF = preload("res://ui/player_interface/volume-xmark-solid-full.svg")
const ICON_MICROPHONE_ON = preload("res://ui/player_interface/microphone-solid-full.svg")
const ICON_MICROPHONE_OFF = preload("res://ui/player_interface/microphone-slash-solid-full.svg")

var speaker_status = true
var microphone_status = true

var bus_master_index = 0
var bus_record_index = 0

@onready var crosshair: Control = %Crosshair
@onready var button_speaker = $HUD/Control/AudioContainer/ButtonSpeaker
@onready var button_microphone = $HUD/Control/AudioContainer/ButtonMicrophone

func _ready() -> void:
	if not is_multiplayer_authority():
		hide()
	else:
		bus_master_index = AudioServer.get_bus_index("Master")
		bus_record_index = AudioServer.get_bus_index("Record")

## Use this method if you want to draw a custom crosshair. Remove if you want to use a custom image for the crosshair
func _draw_crosshair() -> void:
	crosshair.draw_circle(Vector2.ZERO, 1.0, Color.WHITE)


func _on_crosshair_draw() -> void:
	_draw_crosshair()


func _on_button_speaker_pressed() -> void:
	if speaker_status == true:
		speaker_status = false
		button_speaker.icon = ICON_SPEAKER_OFF
		button_speaker.add_theme_color_override("icon_normal_color", Color(1,0,0,1))
		AudioServer.set_bus_mute(bus_master_index, true)
	else:
		speaker_status = true
		button_speaker.icon = ICON_SPEAKER_ON
		button_speaker.add_theme_color_override("icon_normal_color", Color(1,1,1,1))
		AudioServer.set_bus_mute(bus_master_index, false)


func _on_button_microphone_pressed() -> void:
	if microphone_status == true:
		microphone_status = false
		button_microphone.icon = ICON_MICROPHONE_OFF
		button_microphone.add_theme_color_override("icon_normal_color", Color(1,0,0,1))
		AudioServer.set_bus_mute(bus_record_index, true)
	else:
		microphone_status = true
		button_microphone.icon = ICON_MICROPHONE_ON
		button_microphone.add_theme_color_override("icon_normal_color", Color(1,1,1,1))
		AudioServer.set_bus_mute(bus_record_index, false)
