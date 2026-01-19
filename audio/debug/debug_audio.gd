extends Node

func audio_debug_button_pressed(action: String):
	match action:
		"debug":
			Wwise.post_event("bip_100ms_test", AudioManager)
		"start_music":
			Wwise.post_event("play_bgm_test", AudioManager)
		"stop_music":
			Wwise.post_event("stop_bgm_test", AudioManager)
		"sandbox":
			Wwise.set_state("background_music_test", "sandbox")
		"menu":
			Wwise.set_state("background_music_test", "menu")
		"none":
			Wwise.set_state("background_music_test", "None")
