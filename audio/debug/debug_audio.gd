extends Node

func audio_debug_button_pressed(action: String):
	match action:
		"debug":
			Wwise.post_event("test_bip_100ms", AudioManager)
		"start_music":
			Wwise.post_event("play_bgm", AudioManager)
		"stop_music":
			Wwise.post_event("stop_bgm", AudioManager)
		"sandbox":
			Wwise.set_state("background_music", "sandbox")
		"menu":
			Wwise.set_state("background_music", "menu")
		"none":
			Wwise.set_state("background_music", "None")
