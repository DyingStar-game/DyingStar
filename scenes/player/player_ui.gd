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

# Reticle manager: draws the permanent small dot (base) AND the on-demand
# aim/overlay crosshairs. Single place responsible for all crosshair drawing.
var crosshair_manager: CrosshairManager = null

@onready var crosshair: Control = %Crosshair
@onready var button_speaker = $HUD/Control/AudioContainer/ButtonSpeaker
@onready var button_microphone = $HUD/Control/AudioContainer/ButtonMicrophone

func _ready() -> void:
	if not is_multiplayer_authority():
		hide()
	else:
		bus_master_index = AudioServer.get_bus_index("Master")
		bus_record_index = AudioServer.get_bus_index("Record")
		_setup_crosshair_manager()

# ── Aim crosshairs: delegated to CrosshairManager (reusable helper) ──────────
# The manager is placed in the same centered container as the small dot
# (CenterContainer) so its drawings are centered on screen.
func _setup_crosshair_manager() -> void:
	crosshair_manager = CrosshairManager.new()
	crosshair_manager.name = "CrosshairManager"
	crosshair.get_parent().add_child(crosshair_manager)

## Enable/disable the aim crosshair (aim mode / right-click).
func set_aiming(aiming: bool) -> void:
	if crosshair_manager:
		crosshair_manager.set_style("aim" if aiming else "")


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
