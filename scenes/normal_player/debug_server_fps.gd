extends RichTextLabel

func _ready() -> void:
	visible = false

func _set_gameserver_server_fps(fps):
	if fps >= 30:
		text = "[color=green]" + str(int(fps)) + "[/color] FPS"
	else:
		text = "[color=red]" + str(int(fps)) + "[/color] FPS"

func _disconnect():
	pass

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		NetworkOrchestrator.set_gameserver_server_fps.connect(_set_gameserver_server_fps)
	else:
		visible = false
		NetworkOrchestrator.set_gameserver_server_fps.disconnect(_disconnect)
