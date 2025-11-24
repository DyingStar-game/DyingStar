extends Label

func _ready() -> void:
	NetworkOrchestrator.set_gameserver_number_players.connect(_set_gameserver_number_players)

func _set_gameserver_number_players(number_players_server):
	text = str(int(number_players_server)) + " players"
