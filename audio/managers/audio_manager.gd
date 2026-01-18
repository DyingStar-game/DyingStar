extends Node

func _ready():
	#Wwise.set_state("background_music", "None")
	Wwise.post_event("play_bgm", self)
	
	# Suspend wwise if serveur (not ideal solution) the ideal solution would to don't initialised
	if OS.has_feature("dedicated_server"):
		print("Server instance", OS)
		Wwise.suspend(true)
