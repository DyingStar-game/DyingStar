extends Label

func _ready() -> void:
	visible = false

func _set_gameserver_name(name):
	text = "server name: " + name

func _disconnect():
	pass

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		NetworkOrchestrator.set_gameserver_name.connect(_set_gameserver_name)
	else:
		visible = false
		NetworkOrchestrator.set_gameserver_name.disconnect(_disconnect)
