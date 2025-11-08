extends Control

@onready var general : HSlider = $MarginContainer/VBoxContainer/general/HSlider
@onready var music : HSlider = $MarginContainer/VBoxContainer/music/HSlider
@onready var sfx : HSlider = $MarginContainer/VBoxContainer/sfx/HSlider
@onready var voip : HSlider = $MarginContainer/VBoxContainer/voip/HSlider

func _ready() -> void:
	#general.value = 100.0
	#music.value = 100.0
	#sfx.value = 100.0
	#voip.value = 100.0
	
	#general.value_changed.connect(_on_slider_value_changed.bind("Master"))
	#music.value_changed.connect(_on_slider_value_changed.bind("music"))
	#sfx.value_changed.connect(_on_slider_value_changed.bind("sfx"))
	#voip.value_changed.connect(_on_slider_value_changed.bind("voip"))
	pass

func _on_mute_button_pressed(mute : bool, bus : String) -> void:
	pass

func _on_slider_value_changed(volume : float, bus : String) -> void:
	pass
