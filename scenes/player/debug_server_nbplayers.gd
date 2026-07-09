extends Label

func _ready() -> void:
	visible = false

func _set_gameserver_number_players(number_players_server):
	text = str(int(number_players_server)) + " players"

func _disconnect():
	pass

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		NetworkOrchestrator.set_gameserver_number_players.connect(_set_gameserver_number_players)
	else:
		visible = false
		NetworkOrchestrator.set_gameserver_number_players.disconnect(_disconnect)
