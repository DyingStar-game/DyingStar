extends Control

@onready var microphone_device = $MarginContainer/VBoxContainer/Microphone/OptionButton
@onready var speaker_device = $MarginContainer/VBoxContainer/Speaker/OptionButton

@onready var sliders = {
	"Master": $MarginContainer/VBoxContainer/General/HSlider,
	"Music": $MarginContainer/VBoxContainer/Music/HSlider,
	"SFX": $MarginContainer/VBoxContainer/SFX/HSlider,
	"Voice": $MarginContainer/VBoxContainer/VoIP/HSlider
}

func _ready() -> void:
	load_microphone_devices()
	load_speaker_devices()
	
	# Initialise la position des sliders selon le volume actuel
	for bus_name in sliders:
		var slider = sliders[bus_name]
		if slider:
			slider.value = AudioManager.get_bus_volume_linear(bus_name)
			# Connecter le signal pour la mise à jour en temps réel
			slider.value_changed.connect(_on_slider_value_changed.bind(bus_name))
	
	# Écoute les changements externes (ex: si un autre menu change le volume)
	AudioManager.volume_changed.connect(_on_audio_manager_volume_changed)

func _on_slider_value_changed(new_value: float, bus_name: String):
	# Mise à jour immédiate du bus audio
	AudioManager.set_bus_volume_linear(bus_name, new_value)

func _on_audio_manager_volume_changed(bus_name: String, linear_value: float):
	# Mise à jour de l'UI si le volume change ailleurs
	if sliders.has(bus_name):
		var slider = sliders[bus_name]
		if abs(slider.value - linear_value) > 0.01: # Évite les boucles infinies
			slider.value = linear_value

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
