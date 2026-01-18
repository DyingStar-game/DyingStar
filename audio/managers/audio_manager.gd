extends Node

func _ready():
	#Wwise.set_state("background_music", "None")
	Wwise.post_event("play_bgm", self)
	if OS.has_feature("dedicated_server"):
		print("Server instance", OS)
