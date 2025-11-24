extends RichTextLabel

func _ready() -> void:
	NetworkOrchestrator.set_gameserver_server_fps.connect(_set_gameserver_server_fps)

func _set_gameserver_server_fps(fps):
	if fps >= 30:
		text = "[color=green]" + str(int(fps)) + "[/color] FPS"
	else:
		text = "[color=red]" + str(int(fps)) + "[/color] FPS"
