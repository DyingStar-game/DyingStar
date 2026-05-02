extends Control

@onready var general : HSlider = $MarginContainer/VBoxContainer/General/HSlider
@onready var music : HSlider = $MarginContainer/VBoxContainer/Music/HSlider
@onready var sfx : HSlider = $MarginContainer/VBoxContainer/SFX/HSlider
@onready var voip : HSlider = $MarginContainer/VBoxContainer/VoIP/HSlider
@onready var microphone_device = $MarginContainer/VBoxContainer/Microphone/OptionButton
@onready var speaker_device = $MarginContainer/VBoxContainer/Speaker/OptionButton

func _ready() -> void:
	#general.value = 100.0
	#music.value = 100.0
	#sfx.value = 100.0
	#voip.value = 100.0

	#general.value_changed.connect(_on_slider_value_changed.bind("Master"))
	#music.value_changed.connect(_on_slider_value_changed.bind("music"))
	#sfx.value_changed.connect(_on_slider_value_changed.bind("sfx"))
	#voip.value_changed.connect(_on_slider_value_changed.bind("voip"))
	load_microphone_devices()
	load_speaker_devices()

# func _on_mute_button_pressed(mute : bool, bus : String) -> void:
# 	pass

# func _on_slider_value_changed(volume : float, bus : String) -> void:
# 	pass

func load_microphone_devices() -> void:
	var devices: PackedStringArray = AudioServer.get_input_device_list()
	for device in devices:
		microphone_device.add_item(device)

func load_speaker_devices() -> void:
	var devices: PackedStringArray = AudioServer.get_output_device_list()
	for device in devices:
		speaker_device.add_item(device)


func _on_button_pressed() -> void:
	var bus_idx = AudioServer.get_bus_index("Record")
	$AudioStreamPlayer.playing = true
