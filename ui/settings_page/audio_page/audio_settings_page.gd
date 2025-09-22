extends Control

@onready var General : HSlider = $MarginContainer/VBoxContainer/General/HSlider
@onready var Music : HSlider = $MarginContainer/VBoxContainer/Music/HSlider
@onready var SFX : HSlider = $MarginContainer/VBoxContainer/SFX/HSlider
@onready var VoIP : HSlider = $MarginContainer/VBoxContainer/VoIP/HSlider

func _ready() -> void:
	General.value = 100
	Music.value = 100
	SFX.value = 100
	VoIP.value = 100
	
	General.value_changed.connect(_on_slider_value_changed.bind("Master"))
	Music.value_changed.connect(_on_slider_value_changed.bind("Music"))
	SFX.value_changed.connect(_on_slider_value_changed.bind("SFX"))
	VoIP.value_changed.connect(_on_slider_value_changed.bind("VoIP"))

func _on_mute_button_pressed(mute : bool, bus : String) -> void:
	pass

func _on_slider_value_changed(volume : float, bus : String) -> void:
	pass
