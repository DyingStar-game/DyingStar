extends Node

@onready var music_slider = $"Control/MarginContainer/Control/Sliders/Music Fader/HBoxContainer/MusicSlider"
@onready var listener = AudioManager.get_node("/root/AudioManager/menu_listener")

func _ready() -> void:
	Wwise.register_game_obj(self, "GlobalAudio")

func audio_debug_button_pressed(action: String):
	match action:
		"debug":
			Wwise.post_event("bip_100ms_test", AudioManager)
		"start_music":
			Wwise.post_event("play_bgm_test", AudioManager)
			var music_volume = Wwise.get_rtpc_value("Music_Fader", listener)
			music_slider.value = music_volume
		"stop_music":
			Wwise.post_event("stop_bgm_test", AudioManager)
		"sandbox":
			Wwise.set_state("background_music_test", "sandbox")
		"menu":
			Wwise.set_state("background_music_test", "menu")
		"none":
			Wwise.set_state("background_music_test", "None")
		"start_engine":
			Wwise.post_event("Vehicule_START_test", AudioManager)
			var engine_slider = $"Control/MarginContainer/Control/Sliders/Engine Slider/EngineSlider"
			engine_slider.value = Wwise.get_rtpc_value("RPM", AudioManager)
		"stop_engine":
			Wwise.post_event("Vehicule_STOP_test", AudioManager)

func slider_debug(value: float, action: String):
	#print(value)
	match action:
		"music":
			Wwise.set_rtpc_value("Music_Fader", value, listener)
			# Careful with this one, it can make volume really loud
			#Wwise.set_game_object_output_bus_volume(AudioManager, listener, value)
		"engine":
			#fader.value = Wwise.get_rtpc_value("RPM", AudioManager);
			Wwise.set_rtpc_value("RPM", value, AudioManager)
			print("RPM : ", Wwise.get_rtpc_value("RPM", AudioManager))
			
func mute(muted: bool):
	if muted:
		Wwise.set_rtpc_value("Music_Fader", 0, listener)
	else:
		Wwise.set_rtpc_value("Music_Fader", music_slider.value, listener)
	
