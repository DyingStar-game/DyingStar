extends Label

func _ready() -> void:
	visible = false

func _set_gameserver_number_scenes(number_scenes_server):
	text = str(int(number_scenes_server)) + " scenes"

func _disconnect():
	pass

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		NetworkOrchestrator.set_gameserver_number_scenes.connect(_set_gameserver_number_scenes)
	else:
		visible = false
		NetworkOrchestrator.set_gameserver_number_scenes.disconnect(_disconnect)
