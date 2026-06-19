extends Control

## Wires the audio options to SettingsManager (apply + persist) and reflects the current state.
## The mic "Test" button monitors the microphone (you hear yourself) and turns green while active.

const TEST_GREEN : Color = Color(0.2, 0.7, 0.25)

@onready var general : HSlider = $MarginContainer/VBoxContainer/General/HSlider
@onready var music : HSlider = $MarginContainer/VBoxContainer/Music/HSlider
@onready var sfx : HSlider = $MarginContainer/VBoxContainer/SFX/HSlider
@onready var voip : HSlider = $MarginContainer/VBoxContainer/VoIP/HSlider
@onready var microphone_device : OptionButton = $MarginContainer/VBoxContainer/Microphone/OptionButton
@onready var speaker_device : OptionButton = $MarginContainer/VBoxContainer/Speaker/OptionButton
@onready var test_button : Button = $MarginContainer/VBoxContainer/Microphone_testing/Button
@onready var mic_player : AudioStreamPlayer = $AudioStreamPlayer

func _ready() -> void:
	general.value = SettingsManager.get_audio_volume("general")
	music.value = SettingsManager.get_audio_volume("music")
	sfx.value = SettingsManager.get_audio_volume("sfx")
	voip.value = SettingsManager.get_audio_volume("voip")
	general.value_changed.connect(func(v: float) -> void: SettingsManager.set_audio_volume("general", v))
	music.value_changed.connect(func(v: float) -> void: SettingsManager.set_audio_volume("music", v))
	sfx.value_changed.connect(func(v: float) -> void: SettingsManager.set_audio_volume("sfx", v))
	voip.value_changed.connect(func(v: float) -> void: SettingsManager.set_audio_volume("voip", v))
	load_microphone_devices()
	load_speaker_devices()
	microphone_device.item_selected.connect(
		func(i: int) -> void: SettingsManager.set_audio_device("microphone", microphone_device.get_item_text(i)))
	speaker_device.item_selected.connect(
		func(i: int) -> void: SettingsManager.set_audio_device("speaker", speaker_device.get_item_text(i)))
	test_button.toggle_mode = true
	test_button.toggled.connect(_on_test_toggled)

## List the input devices and pre-select the active one.
func load_microphone_devices() -> void:
	microphone_device.clear()
	var devices: PackedStringArray = AudioServer.get_input_device_list()
	for i in devices.size():
		microphone_device.add_item(devices[i])
		if devices[i] == AudioServer.input_device:
			microphone_device.select(i)

## List the output devices and pre-select the active one.
func load_speaker_devices() -> void:
	speaker_device.clear()
	var devices: PackedStringArray = AudioServer.get_output_device_list()
	for i in devices.size():
		speaker_device.add_item(devices[i])
		if devices[i] == AudioServer.output_device:
			speaker_device.select(i)

## Mic test: play the microphone back so you hear yourself, and turn the button green while on.
func _on_test_toggled(on: bool) -> void:
	mic_player.playing = on
	if on:
		var style := StyleBoxFlat.new()
		style.bg_color = TEST_GREEN
		test_button.add_theme_stylebox_override("normal", style)
		test_button.add_theme_stylebox_override("hover", style)
		test_button.add_theme_stylebox_override("pressed", style)
	else:
		test_button.remove_theme_stylebox_override("normal")
		test_button.remove_theme_stylebox_override("hover")
		test_button.remove_theme_stylebox_override("pressed")

## Stop monitoring the mic if the page is closed while a test is running.
func _exit_tree() -> void:
	if mic_player != null:
		mic_player.playing = false
