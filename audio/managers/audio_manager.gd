extends Node

func _ready():
	if OS.has_feature("dedicated_server"):
		print("Server instance", OS)
