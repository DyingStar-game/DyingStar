extends Label

func _ready() -> void:
	visible = false

func _set_universe_servers(number_servers):
	text = str(int(number_servers)) + " servers"

func _disconnect():
	pass

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		NetworkOrchestrator.set_universe_servers.connect(_set_universe_servers)
	else:
		visible = false
		NetworkOrchestrator.set_universe_servers.disconnect(_disconnect)
