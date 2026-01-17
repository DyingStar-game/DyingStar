extends Node

func on_button_pressed(action: String):
	match action:
		"debug":
			print("debug button pressed")
			Wwise.post_event("test_bip_100ms", self)

		"start_music":
			Wwise.post_event("play_bgm", self)

		"sandbox":
			Wwise.set_state("background_music", "sandbox")

		"menu":
			Wwise.set_state("background_music", "menu")

		"none":
			Wwise.set_state("background_music", "None")
