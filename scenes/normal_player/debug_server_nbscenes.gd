extends Label

func _ready() -> void:
	NetworkOrchestrator.set_gameserver_number_scenes.connect(_set_gameserver_number_scenes)

func _set_gameserver_number_scenes(number_scenes_server):
	text = str(int(number_scenes_server)) + " scenes"
