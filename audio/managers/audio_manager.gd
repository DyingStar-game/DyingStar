extends Node

func _ready():
	if OS.has_feature("dedicated_server"):
		print("Server instance", OS)
		# Wwise.suspend gives an error but it works for now. If a Godot dev comes by, feel free to make it better. Best Regards, Audio Team.
		Wwise.suspend(false)

func start_music():
	Wwise.post_event("play_bgm_test", AudioManager)

func set_music_state(bgm_state: String):
	Wwise.set_state("background_music", bgm_state)

func set_audio_listener(camera):
	var menuListener = get_node("/root/AudioManager/menu_listener")
	Wwise.remove_default_listener(menuListener)
	Wwise.add_default_listener(camera)
